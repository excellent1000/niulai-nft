// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeV3SwapRouter, IWBNB} from "./interfaces/IExternal.sol";

interface INiuLaiNFT {
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title NiuLaiVault — 版税金库 / 每小时买入 $牛来 / 自动分发给 NFT 持有者
/// @notice 流程（每小时一轮）：
///   1. 市场把 10% 版税（BNB 或 WBNB）打到本合约；网站铸造收入也可按比例打进来。
///   2. keeper 调 harvest(minOut)：把全部 BNB（扣除 keeper 报酬）经 PancakeSwap V3 多跳（BNB→USDT→牛来）买成 $牛来，开启一轮分发。
///   3. 任何人调 distribute(count)：按 tokenId 1..totalSupply 分批遍历，同一持有人在批内聚合后直接转账（transient storage 聚合，省 gas）。
///      被 exclude 的地址（市场托管合约、黑洞等）跳过，其份额留在金库进入下一轮。
///   4. 本轮发完（cursor == roundSupply）才允许下一次 harvest。
contract NiuLaiVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardToken;   // $牛来 0xbeea1d618e533a387d941f58a7d4c9b7bd377777
    IWBNB public immutable wbnb;
    INiuLaiNFT public immutable nft;

    IPancakeV3SwapRouter public router;
    bytes public swapPath;                 // WBNB ‖ fee ‖ USDT ‖ fee ‖ 牛来

    uint256 public interval = 1 hours;
    uint256 public lastHarvest;
    uint256 public minHarvestAmount = 0.01 ether;   // 少于这个数不值得买
    uint16 public callerRewardBps = 50;              // harvest 调用者报酬（BNB，万分比，≤5%）
    uint256 public distributeReward;                 // 每次 distribute 调用者的 BNB 报酬（默认 0）
    bool public publicHarvest;                       // true 时任何人可 harvest（仍需自带 minOut）
    mapping(address => bool) public keepers;
    mapping(address => bool) public excluded;        // 不参与分红的地址
    mapping(address => bytes) public tokenSwapPath;  // 其他币种版税（如 USDT）→ $牛来 的 V3 路径

    // 当前分发轮次
    uint256 public roundId;
    uint256 public roundAmount;     // 本轮待分发总量（$牛来）
    uint256 public roundSupply;     // 本轮快照的 NFT 总量
    uint256 public roundShare;      // 每个 NFT 的份额 = roundAmount / roundSupply
    uint256 public cursor;          // 已处理到的 tokenId（0 表示未开始）
    bool public roundActive;

    // 统计
    uint256 public totalBnbSpent;
    uint256 public totalTokenBought;
    uint256 public totalTokenDistributed;
    uint256 public totalSkipped;    // 被排除地址的份额（留在金库）

    event Harvested(uint256 indexed roundId, address indexed caller, uint256 bnbIn, uint256 tokenOut, uint256 callerReward);
    event Distributed(uint256 indexed roundId, uint256 fromId, uint256 toId, uint256 holders, uint256 amount);
    event RoundFinished(uint256 indexed roundId, uint256 distributed);
    event Excluded(address indexed account, bool excluded);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event SwapConfigUpdated(address router, bytes path);
    event Donated(address indexed from, uint256 amount);
    event TokenHarvested(uint256 indexed roundId, address indexed token, uint256 amountIn, uint256 tokenOut);
    event TokenSwapPathUpdated(address indexed token, bytes path);

    error NotKeeper();
    error TooEarly();
    error TooSmall();
    error RoundInProgress();
    error NoRound();
    error TransferFailed();
    error BadParam();

    constructor(
        address initialOwner,
        address rewardToken_,
        address wbnb_,
        address nft_,
        address router_,
        bytes memory swapPath_
    ) Ownable(initialOwner) {
        if (rewardToken_ == address(0) || wbnb_ == address(0) || nft_ == address(0) || router_ == address(0)) revert BadParam();
        rewardToken = IERC20(rewardToken_);
        wbnb = IWBNB(wbnb_);
        nft = INiuLaiNFT(nft_);
        router = IPancakeV3SwapRouter(router_);
        swapPath = swapPath_;
        keepers[initialOwner] = true;
        excluded[address(0)] = true;
        excluded[address(0xdead)] = true;
    }

    receive() external payable {}

    // ============ 视图 ============

    /// @notice 供 keeper/前端查询：现在能否 harvest、可用 BNB（含 WBNB）
    function canHarvest() external view returns (bool ready, uint256 available, uint256 nextTime) {
        available = address(this).balance + wbnb.balanceOf(address(this));
        nextTime = lastHarvest == 0 ? block.timestamp : lastHarvest + interval;
        ready = !roundActive && block.timestamp >= nextTime && available >= minHarvestAmount && nft.totalSupply() > 0;
    }

    /// @notice 本轮还有多少个 tokenId 没分
    function remainingInRound() external view returns (uint256) {
        return roundActive ? roundSupply - cursor : 0;
    }

    // ============ 每小时买入 ============

    /// @param minOut 最少买到多少 $牛来（keeper 用 QuoterV2 报价 × (1-滑点) 算出，防三明治）
    function harvest(uint256 minOut) external nonReentrant returns (uint256 out) {
        bool privileged = msg.sender == owner() || keepers[msg.sender];
        if (!privileged && !publicHarvest) revert NotKeeper();
        if (roundActive) revert RoundInProgress();
        if (msg.sender != owner() && lastHarvest != 0 && block.timestamp < lastHarvest + interval) revert TooEarly();

        _unwrapWBNB();
        uint256 bal = address(this).balance;
        if (bal < minHarvestAmount) revert TooSmall();

        uint256 reward = (bal * callerRewardBps) / 10_000;
        uint256 amountIn = bal - reward;
        lastHarvest = block.timestamp;

        out = router.exactInput{value: amountIn}(
            IPancakeV3SwapRouter.ExactInputParams({
                path: swapPath,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        totalBnbSpent += amountIn;
        totalTokenBought += out;

        _openRound(out);

        if (reward > 0) {
            (bool ok,) = msg.sender.call{value: reward}("");
            if (!ok) revert TransferFailed();
        }
        emit Harvested(roundId, msg.sender, amountIn, out, reward);
    }

    /// @notice 市场用 USDT 等 ERC20 结算的版税：把某个币种的全部余额换成 $牛来 并开一轮分发。
    ///         需先 setTokenSwapPath(token, path)。仅 keeper/owner，且同样必须自带 minOut。
    function harvestToken(address token, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (msg.sender != owner() && !keepers[msg.sender]) revert NotKeeper();
        if (roundActive) revert RoundInProgress();
        if (token == address(rewardToken) || token == address(wbnb)) revert BadParam();
        bytes memory path = tokenSwapPath[token];
        if (path.length < 43) revert BadParam();
        uint256 amountIn = IERC20(token).balanceOf(address(this));
        if (amountIn == 0) revert TooSmall();
        IERC20(token).forceApprove(address(router), amountIn);
        out = router.exactInput(
            IPancakeV3SwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        totalTokenBought += out;
        _openRound(out);
        emit TokenHarvested(roundId, token, amountIn, out);
    }

    /// @notice 直接捐 $牛来 进来并立刻开一轮分发（项目方其他收入）。仅 owner/keeper：
    ///         防止任何人用几 wei 的"捐赠"反复开轮次，逼 keeper 花 gas 分发灰尘。
    ///         普通人想贡献直接 transfer $牛来 到本合约即可，会并入下一轮。
    function donate(uint256 amount) external nonReentrant {
        if (msg.sender != owner() && !keepers[msg.sender]) revert NotKeeper();
        if (roundActive) revert RoundInProgress();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Donated(msg.sender, amount);
        _openRound(amount);
    }

    function _openRound(uint256 amount) internal {
        uint256 supply = nft.totalSupply();
        if (supply == 0) revert BadParam();
        // 把之前轮次剩余（被排除份额 + 除不尽的尾数）一起并入：本轮分发的是金库里全部 $牛来
        amount = rewardToken.balanceOf(address(this));
        roundId += 1;
        roundAmount = amount;
        roundSupply = supply;
        roundShare = amount / supply;
        cursor = 0;
        roundActive = roundShare > 0;
    }

    // ============ 自动分发 ============

    /// @notice 分发下一批 count 个 tokenId 的份额给持有人；任何人可调（安全：只按快照份额转账）
    function distribute(uint256 count) external nonReentrant {
        if (!roundActive) revert NoRound();
        uint256 start = cursor;
        uint256 end = start + count;
        if (end > roundSupply) end = roundSupply;
        if (end <= start) revert BadParam();

        address[] memory holders = new address[](end - start);
        uint256 n;
        uint256 share = roundShare;
        uint256 skipped;
        // 批内按持有人聚合（transient storage，key 加 start 盐避免同一 tx 多次调用串味）
        for (uint256 id = start + 1; id <= end; id++) {
            address o = nft.ownerOf(id);
            if (excluded[o]) {
                skipped += share;
                continue;
            }
            bytes32 key = keccak256(abi.encode(o, start));
            uint256 cur;
            assembly { cur := tload(key) }
            if (cur == 0) holders[n++] = o;
            assembly { tstore(key, add(cur, share)) }
        }
        uint256 sent;
        for (uint256 i = 0; i < n; i++) {
            address o = holders[i];
            bytes32 key = keccak256(abi.encode(o, start));
            uint256 amt;
            assembly { amt := tload(key) tstore(key, 0) }
            rewardToken.safeTransfer(o, amt);
            sent += amt;
        }
        cursor = end;
        totalTokenDistributed += sent;
        totalSkipped += skipped;
        emit Distributed(roundId, start + 1, end, n, sent);

        if (end == roundSupply) {
            roundActive = false;
            emit RoundFinished(roundId, sent);
        }
        if (distributeReward > 0 && address(this).balance >= distributeReward) {
            (bool ok,) = msg.sender.call{value: distributeReward}("");
            ok; // 报酬发不出去不影响分发
        }
    }

    // ============ 管理 ============

    function setSwapConfig(address router_, bytes calldata path) external onlyOwner {
        if (router_ == address(0) || path.length < 43) revert BadParam();
        router = IPancakeV3SwapRouter(router_);
        swapPath = path;
        emit SwapConfigUpdated(router_, path);
    }

    function setTokenSwapPath(address token, bytes calldata path) external onlyOwner {
        if (token == address(0) || (path.length != 0 && path.length < 43)) revert BadParam();
        tokenSwapPath[token] = path;
        emit TokenSwapPathUpdated(token, path);
    }

    function setInterval(uint256 interval_) external onlyOwner {
        if (interval_ < 10 minutes || interval_ > 7 days) revert BadParam();
        interval = interval_;
    }

    function setMinHarvestAmount(uint256 amount) external onlyOwner {
        minHarvestAmount = amount;
    }

    function setRewards(uint16 callerRewardBps_, uint256 distributeReward_) external onlyOwner {
        if (callerRewardBps_ > 500) revert BadParam();
        callerRewardBps = callerRewardBps_;
        distributeReward = distributeReward_;
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    function setPublicHarvest(bool allowed) external onlyOwner {
        publicHarvest = allowed;
    }

    function setExcluded(address account, bool isExcluded) external onlyOwner {
        excluded[account] = isExcluded;
        emit Excluded(account, isExcluded);
    }

    /// @notice 误转进来的其他代币；不能动 $牛来（那是持有者的）
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(rewardToken)) revert BadParam();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice 紧急提取 BNB（例如 router 失效需要迁移）。会公开在链上，请谨慎使用。
    function emergencyWithdrawBNB(address payable to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        if (!ok) revert TransferFailed();
    }

    function _unwrapWBNB() internal {
        uint256 w = wbnb.balanceOf(address(this));
        if (w > 0) wbnb.withdraw(w);
    }
}
