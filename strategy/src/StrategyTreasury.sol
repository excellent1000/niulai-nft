// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title StrategyTreasury —— 牛来永动机
/// @notice 资金流：
///   $NLSTR 每笔 swap 的 10% 手续费（金库是唯一 LP）→ collectFees() 提取
///     ├─ 80% → nftFund：常驻收单价买入 牛来 NFT
///     ├─ 10% → 现有分红金库（每小时买 $牛来 分给 999 位 NFT 持有者）
///     └─ 10% → 团队
///   卖单侧收到的手续费是 NLSTR → 直接销毁
///
///   NFT 循环：
///     sellToTreasury  任何人按 bidPrice 把牛来 NFT 卖给金库（金库额外付 10% 版税给分红池）
///                     每收一枚，bidPrice 自动 +bidStepBps（只涨不跌，有上限）
///     buyFromTreasury 任何人按 bidPrice × askMarkupBps 从金库买走
///                     成交价的 10% 版税给分红池，其余买入 $NLSTR 并销毁
///
/// @dev 本合约**没有**撤出流动性的函数，LP 本金永久锁死。
contract StrategyTreasury is IUnlockCallback, IERC721Receiver, Ownable, ReentrancyGuard {
    using CurrencySettler for Currency;

    enum Action { ADD_LIQUIDITY, COLLECT, BUY_BURN }

    IPoolManager public immutable poolManager;
    IERC721 public immutable nft;             // 牛来 NFT
    address public immutable dividendVault;   // 现有 NiuLaiVault（收 BNB，每小时买 $牛来 分红）
    address public nlstr;                     // $NLSTR
    address public team;
    address public keeper;

    PoolKey public poolKey;
    bool public poolKeySet;

    // ---- 分账（basis points，和 = 10000）
    uint16 public nftFundBps = 8000;   // 80% → 收购 NFT
    uint16 public vaultBps = 1000;     // 10% → 分红池
    uint16 public teamBps = 1000;      // 10% → 团队

    // ---- NFT 做市
    uint256 public bidPrice;                 // 当前收单价（wei）
    uint256 public maxBidPrice;              // 收单价上限
    uint16 public bidStepBps = 200;          // 每收一枚 +2%
    uint16 public askMarkupBps = 12_000;     // 卖出价 = bid × 1.2
    uint16 public royaltyBps = 1000;         // 金库自付版税 10% → 分红池
    bool public bidPaused;

    uint256 public nftFund;                  // 专款：收购 NFT 用的 BNB
    uint256 public totalBought;
    uint256 public totalSold;
    uint256 public totalNlstrBurned;
    uint256 public totalToVault;
    uint256 public totalToTeam;

    uint256[] private _inventory;
    mapping(uint256 => uint256) private _invIndexPlusOne;

    error NotPoolManager();
    error PoolKeyAlreadySet();
    error PoolKeyNotSet();
    error BadSplit();
    error BidDisabled();
    error InsufficientFund();
    error NotForSale();
    error WrongPayment();
    error NotAuthorized();
    error BadParam();
    error TransferFailed();

    event FeesCollected(uint256 bnb, uint256 nlstr);
    event Split(uint256 toNftFund, uint256 toVault, uint256 toTeam);
    event BoughtNft(address indexed seller, uint256 indexed tokenId, uint256 price, uint256 royalty, uint256 newBid);
    event SoldNft(address indexed buyer, uint256 indexed tokenId, uint256 price, uint256 royalty, uint256 burned);
    event NlstrBurned(uint256 amount);
    event BidUpdated(uint256 bidPrice);

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(IPoolManager _poolManager, IERC721 _nft, address _dividendVault, address _team, address _owner)
        Ownable(_owner)
    {
        poolManager = _poolManager;
        nft = _nft;
        dividendVault = _dividendVault;
        team = _team;
        keeper = _owner;
    }

    receive() external payable {}

    // ================================================================ 配置

    function setNlstr(address _nlstr) external onlyOwner {
        if (nlstr != address(0)) revert BadParam();
        nlstr = _nlstr;
    }

    function setPoolKey(PoolKey calldata key) external onlyOwner {
        if (poolKeySet) revert PoolKeyAlreadySet();
        if (Currency.unwrap(key.currency1) != nlstr) revert BadParam();
        poolKey = key;
        poolKeySet = true;
    }

    function setSplit(uint16 _nftFundBps, uint16 _vaultBps, uint16 _teamBps) external onlyOwner {
        if (uint256(_nftFundBps) + _vaultBps + _teamBps != 10_000) revert BadSplit();
        if (_teamBps > 2000) revert BadSplit(); // 团队分成硬上限 20%
        nftFundBps = _nftFundBps;
        vaultBps = _vaultBps;
        teamBps = _teamBps;
    }

    function setMarketConfig(uint256 _maxBidPrice, uint16 _bidStepBps, uint16 _askMarkupBps) external onlyOwner {
        if (_bidStepBps > 2000 || _askMarkupBps < 10_000 || _askMarkupBps > 30_000) revert BadParam();
        maxBidPrice = _maxBidPrice;
        bidStepBps = _bidStepBps;
        askMarkupBps = _askMarkupBps;
    }

    /// @notice 收单价只能由 owner 设定初始值/微调，且不得超过上限
    function setBidPrice(uint256 _bidPrice) external onlyOwner {
        if (maxBidPrice != 0 && _bidPrice > maxBidPrice) revert BadParam();
        bidPrice = _bidPrice;
        emit BidUpdated(_bidPrice);
    }

    function setBidPaused(bool p) external onlyKeeperOrOwner {
        bidPaused = p;
    }

    function setKeeper(address k) external onlyOwner { keeper = k; }
    function setTeam(address t) external onlyOwner { if (t == address(0)) revert BadParam(); team = t; }

    /// @notice 任何人都可以给收购基金充值（也用于开盘前注入启动资金）
    function fundBid() external payable { nftFund += msg.value; }

    // ================================================================ 流动性（只进不出）

    /// @notice 单边加流动性：区间完全在现价之上，只需要投入 NLSTR，不需要 BNB。
    /// @dev 合约里**没有**移除流动性的函数，本金永久锁死。
    function addLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity) external onlyOwner {
        if (!poolKeySet) revert PoolKeyNotSet();
        poolManager.unlock(abi.encode(Action.ADD_LIQUIDITY, abi.encode(tickLower, tickUpper, liquidity)));
    }

    /// @notice 提取累计的 LP 手续费并按 80/10/10 分账；NLSTR 部分直接销毁。任何人可调用。
    function collectFees(int24 tickLower, int24 tickUpper) external nonReentrant {
        if (!poolKeySet) revert PoolKeyNotSet();
        poolManager.unlock(abi.encode(Action.COLLECT, abi.encode(tickLower, tickUpper)));
        _distribute();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));

        if (action == Action.ADD_LIQUIDITY) {
            (int24 lo, int24 hi, uint128 liq) = abi.decode(payload, (int24, int24, uint128));
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: 0}),
                ""
            );
            if (delta.amount0() < 0) poolKey.currency0.settle(poolManager, uint256(uint128(-delta.amount0())));
            if (delta.amount1() < 0) poolKey.currency1.settle(poolManager, uint256(uint128(-delta.amount1())));
        } else if (action == Action.COLLECT) {
            (int24 lo, int24 hi) = abi.decode(payload, (int24, int24));
            (, BalanceDelta fees) = poolManager.modifyLiquidity(
                poolKey, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 0, salt: 0}), ""
            );
            uint256 b0 = fees.amount0() > 0 ? uint256(uint128(fees.amount0())) : 0;
            uint256 b1 = fees.amount1() > 0 ? uint256(uint128(fees.amount1())) : 0;
            if (b0 > 0) poolKey.currency0.take(poolManager, address(this), b0);
            if (b1 > 0) poolKey.currency1.take(poolManager, address(this), b1);
            emit FeesCollected(b0, b1);
        } else {
            // BUY_BURN：用 BNB 买入 NLSTR
            uint256 bnbIn = abi.decode(payload, (uint256));
            BalanceDelta delta = poolManager.swap(
                poolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(bnbIn),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            if (delta.amount0() < 0) poolKey.currency0.settle(poolManager, uint256(uint128(-delta.amount0())));
            if (delta.amount1() > 0) poolKey.currency1.take(poolManager, address(this), uint256(uint128(delta.amount1())));
        }
        return "";
    }

    // ================================================================ 分账

    function _distribute() internal {
        uint256 bnb = address(this).balance - nftFund;
        if (bnb > 0) {
            uint256 toVault = bnb * vaultBps / 10_000;
            uint256 toTeam = bnb * teamBps / 10_000;
            uint256 toFund = bnb - toVault - toTeam;
            nftFund += toFund;
            if (toVault > 0) { _pay(dividendVault, toVault); totalToVault += toVault; }
            if (toTeam > 0) { _pay(team, toTeam); totalToTeam += toTeam; }
            emit Split(toFund, toVault, toTeam);
        }
        _burnNlstrBalance();
    }

    function _burnNlstrBalance() internal {
        uint256 bal = IERC20(nlstr).balanceOf(address(this));
        if (bal > 0) {
            IBurnable(nlstr).burn(bal);
            totalNlstrBurned += bal;
            emit NlstrBurned(bal);
        }
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ================================================================ NFT 做市

    /// @notice 金库买入一枚 NFT 需要花的总额（成交价 + 金库自付的版税）
    function bidCost() public view returns (uint256) {
        return bidPrice + bidPrice * royaltyBps / 10_000;
    }

    /// @notice 金库当前卖出价
    function askPrice() public view returns (uint256) {
        return bidPrice * askMarkupBps / 10_000;
    }

    /// @notice 任何人按收单价把牛来 NFT 卖给金库，立刻拿到 BNB
    function sellToTreasury(uint256 tokenId) external nonReentrant {
        if (bidPaused || bidPrice == 0) revert BidDisabled();
        uint256 price = bidPrice;
        uint256 royalty = price * royaltyBps / 10_000;
        if (nftFund < price + royalty) revert InsufficientFund();

        nftFund -= (price + royalty);
        _inventory.push(tokenId);
        _invIndexPlusOne[tokenId] = _inventory.length;
        totalBought += 1;

        // 收单价阶梯上调（只涨不跌）
        uint256 next = price + price * bidStepBps / 10_000;
        if (maxBidPrice != 0 && next > maxBidPrice) next = maxBidPrice;
        bidPrice = next;

        nft.transferFrom(msg.sender, address(this), tokenId);
        _pay(msg.sender, price);
        if (royalty > 0) { _pay(dividendVault, royalty); totalToVault += royalty; }

        emit BoughtNft(msg.sender, tokenId, price, royalty, next);
        emit BidUpdated(next);
    }

    /// @notice 从金库柜台买走一枚 NFT（价格 = 当前收单价 × 1.2）
    function buyFromTreasury(uint256 tokenId) external payable nonReentrant {
        if (_invIndexPlusOne[tokenId] == 0) revert NotForSale();
        uint256 price = askPrice();
        if (msg.value < price) revert WrongPayment();

        _removeFromInventory(tokenId);
        totalSold += 1;

        uint256 royalty = price * royaltyBps / 10_000;
        uint256 forBurn = price - royalty;
        uint256 refund = msg.value - price;

        nft.transferFrom(address(this), msg.sender, tokenId);
        if (royalty > 0) { _pay(dividendVault, royalty); totalToVault += royalty; }
        if (refund > 0) _pay(msg.sender, refund);

        if (forBurn > 0 && poolKeySet) {
            poolManager.unlock(abi.encode(Action.BUY_BURN, abi.encode(forBurn)));
            _burnNlstrBalance();
        }
        emit SoldNft(msg.sender, tokenId, price, royalty, forBurn);
    }

    function _removeFromInventory(uint256 tokenId) internal {
        uint256 idx = _invIndexPlusOne[tokenId] - 1;
        uint256 last = _inventory.length - 1;
        if (idx != last) {
            uint256 moved = _inventory[last];
            _inventory[idx] = moved;
            _invIndexPlusOne[moved] = idx + 1;
        }
        _inventory.pop();
        delete _invIndexPlusOne[tokenId];
    }

    // ================================================================ 视图

    function inventory() external view returns (uint256[] memory) { return _inventory; }
    function inventorySize() external view returns (uint256) { return _inventory.length; }
    function isForSale(uint256 tokenId) external view returns (bool) { return _invIndexPlusOne[tokenId] != 0; }

    /// @notice 距离下一次能收单还差多少 BNB（前端进度条用）
    function fundProgress() external view returns (uint256 have, uint256 need) {
        return (nftFund, bidCost());
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
