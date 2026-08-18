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
import {IElementEx, IWBNB, NFTBuyOrder, NFTSellOrder, ElementSignature, Fee, Property} from "./ElementTypes.sol";

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

    // ---- Element 集成（让金库的买卖走市场合约，成交才计入成交量/地板价）
    IElementEx public immutable element;
    IWBNB public immutable wbnb;
    uint256 public nextOrderNonce = 1;
    mapping(bytes32 => bool) public approvedListings;   // ERC-1271 授权过的卖单哈希
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;

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
    uint16 public askMarkupBps = 13_500;     // 卖出价 = bid × 1.35（必须盖过两头版税，见 minMarkupBps）
    uint16 public royaltyBps = 1000;         // 金库自付版税 10% → 分红池
    bool public bidPaused;

    uint256 public nftFund;                  // 专款：收购 NFT 用的 BNB
    uint256 public totalBought;
    uint256 public totalSold;
    uint256 public totalNlstrBurned;
    uint256 public totalToVault;
    uint256 public totalToTeam;
    uint256 public totalSaleProceedsBurned;
    uint256 public totalPrincipalRecycled;
    uint256 private _lastCollectedBnb;

    /// 每枚 NFT 的持仓成本（含金库自付的版税）
    mapping(uint256 => uint256) public costBasis;
    /// 已卖出但尚未回流的本金
    uint256 public pendingPrincipal;
    /// 最近一次挂买单的单枚总成本，用作 Element 成交入库时的成本价
    uint256 public pendingOrderCost;

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
    error PriceTooHigh();
    error PriceTooLow();
    error NotOwned();

    event FeesCollected(uint256 bnb, uint256 nlstr);
    event Split(uint256 toNftFund, uint256 toVault, uint256 toTeam);
    event BoughtNft(address indexed seller, uint256 indexed tokenId, uint256 price, uint256 royalty, uint256 newBid);
    event SoldNft(address indexed buyer, uint256 indexed tokenId, uint256 price, uint256 royalty, uint256 burned);
    event NlstrBurned(uint256 amount);
    event BidUpdated(uint256 bidPrice);
    event BuyOrdersPlaced(uint256 count, uint256 price, uint256 firstNonce);
    event ListingApproved(uint256 indexed tokenId, uint256 price, bytes32 hash);
    event OrderCancelled(uint256 nonce);
    event InventoryAdded(uint256 indexed tokenId);
    event InventoryRemoved(uint256 indexed tokenId);
    event PrincipalRecycled(uint256 amount);
    event ProfitBurned(uint256 bnbIn, uint256 nlstrBurned);

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(
        IPoolManager _poolManager, IERC721 _nft, address _dividendVault, address _team, address _owner,
        IElementEx _element, IWBNB _wbnb
    ) Ownable(_owner) {
        element = _element;
        wbnb = _wbnb;
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

    /// @notice 保本所需的最低加价：买入付 (1+r) 倍成本、卖出只到手 (1-r) 倍，
    ///         所以必须 markup × (1−r) > (1+r)，即 markup > (1+r)/(1−r)。
    function minMarkupBps() public view returns (uint16) {
        return uint16((uint256(10_000 + royaltyBps) * 10_000) / (10_000 - royaltyBps)) + 1;
    }

    function setMarketConfig(uint256 _maxBidPrice, uint16 _bidStepBps, uint16 _askMarkupBps) external onlyOwner {
        if (_bidStepBps > 2000 || _askMarkupBps > 30_000) revert BadParam();
        if (_askMarkupBps < minMarkupBps()) revert PriceTooLow();   // 防止设成必亏的加价
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
        _lastCollectedBnb = 0;
        poolManager.unlock(abi.encode(Action.COLLECT, abi.encode(tickLower, tickUpper)));
        _distribute(_lastCollectedBnb);
        _burnNlstrBalance();
    }

    /// @dev NFT 离开金库时把它的成本价记为「待回本金」
    function _onNftLeft(uint256 tokenId) internal {
        uint256 c = costBasis[tokenId];
        if (c > 0) { pendingPrincipal += c; delete costBasis[tokenId]; }
    }

    /// @notice 处理卖 NFT 得来的 BNB：**先把本金还给收购基金，只有盈利部分才买入并销毁 $NLSTR**。
    ///         余额里扣掉 nftFund 剩下的就是卖货所得。任何人可调用。
    function processSaleProceeds() external nonReentrant { _processSaleProceeds(); }

    function _processSaleProceeds() internal {
        uint256 amt = address(this).balance - nftFund;
        if (amt == 0) return;
        // ① 本金回流，继续买 NFT
        uint256 back = amt < pendingPrincipal ? amt : pendingPrincipal;
        if (back > 0) {
            nftFund += back;
            pendingPrincipal -= back;
            totalPrincipalRecycled += back;
            amt -= back;
            emit PrincipalRecycled(back);
        }
        // ② 只有盈利部分买入并销毁
        if (amt > 0 && poolKeySet) {
            poolManager.unlock(abi.encode(Action.BUY_BURN, abi.encode(amt)));
            uint256 burned = IERC20(nlstr).balanceOf(address(this));
            _burnNlstrBalance();
            totalSaleProceedsBurned += burned;
            emit ProfitBurned(amt, burned);
        }
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
            _lastCollectedBnb = b0;
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

    function _distribute(uint256 bnb) internal {
        if (bnb > 0) {
            uint256 toVault = bnb * vaultBps / 10_000;
            uint256 toTeam = bnb * teamBps / 10_000;
            uint256 toFund = bnb - toVault - toTeam;
            nftFund += toFund;
            if (toVault > 0) { _pay(dividendVault, toVault); totalToVault += toVault; }
            if (toTeam > 0) { _pay(team, toTeam); totalToTeam += toTeam; }
            emit Split(toFund, toVault, toTeam);
        }
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

    /// @notice 金库柜台标价（买家实付）
    function askPrice() public view returns (uint256) {
        return bidPrice * askMarkupBps / 10_000;
    }

    /// @notice 挂到 Element 时允许的最低「卖家净收」
    function minSellNet() public view returns (uint256) {
        return askPrice() * (10_000 - royaltyBps) / 10_000;
    }

    /// @notice 任何人按收单价把牛来 NFT 卖给金库，立刻拿到 BNB
    function sellToTreasury(uint256 tokenId) external nonReentrant {
        if (bidPaused || bidPrice == 0) revert BidDisabled();
        uint256 price = bidPrice;
        uint256 royalty = price * royaltyBps / 10_000;
        if (nftFund < price + royalty) revert InsufficientFund();

        nftFund -= (price + royalty);
        costBasis[tokenId] = price + royalty;
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
        uint256 refund = msg.value - price;
        _onNftLeft(tokenId);

        nft.transferFrom(address(this), msg.sender, tokenId);
        if (royalty > 0) { _pay(dividendVault, royalty); totalToVault += royalty; }
        if (refund > 0) _pay(msg.sender, refund);

        _processSaleProceeds();   // 先回本金，只烧利润
        emit SoldNft(msg.sender, tokenId, price, royalty, price - royalty);
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

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        // Element 成交或任何人 safeTransfer 进来的牛来 NFT 自动入库
        if (msg.sender == address(nft) && _invIndexPlusOne[tokenId] == 0) {
            _inventory.push(tokenId);
            _invIndexPlusOne[tokenId] = _inventory.length;
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    // ================================================================ Element 集成

    /// @notice ERC-1271：Element 会回调这里校验金库挂的卖单
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return approvedListings[hash] ? ERC1271_MAGIC : bytes4(0);
    }

    /// @notice 在 Element 上挂 count 张「合集通吃」买单（一张只能成交一次，所以要多挂几张）
    /// @dev 价格不得高于当前 bidPrice —— 即使 keeper 私钥泄露也无法高价乱买
    function placeBuyOrders(uint256 count, uint256 price, uint256 expiry)
        external onlyKeeperOrOwner nonReentrant
    {
        if (price > bidPrice || price == 0) revert PriceTooHigh();
        if (count == 0 || count > 20) revert BadParam();
        uint256 royalty = price * royaltyBps / 10_000;
        uint256 need = (price + royalty) * count;
        uint256 have = wbnb.balanceOf(address(this));
        if (need > have) {
            uint256 shortfall = need - have;
            if (nftFund < shortfall) revert InsufficientFund();
            nftFund -= shortfall;
            wbnb.deposit{value: shortfall}();
        }
        wbnb.approve(address(element), type(uint256).max);

        pendingOrderCost = price + royalty;
        uint256 first = nextOrderNonce;
        for (uint256 i = 0; i < count; i++) {
            NFTBuyOrder memory o;
            o.maker = address(this);
            o.taker = address(0);
            o.expiry = expiry;
            o.nonce = nextOrderNonce++;
            o.erc20Token = address(wbnb);
            o.erc20TokenAmount = price;
            o.fees = new Fee[](1);
            o.fees[0] = Fee({recipient: dividendVault, amount: royalty, feeData: ""});
            o.nft = address(nft);
            o.nftId = 0;
            o.nftProperties = new Property[](1);
            o.nftProperties[0] = Property({propertyValidator: address(0), propertyData: ""});
            element.preSignERC721BuyOrder(o);
        }
        emit BuyOrdersPlaced(count, price, first);
    }

    /// @notice 授权一张卖单（ERC-1271）。价格不得低于柜台价 —— keeper 无法低价甩卖
    function approveListing(NFTSellOrder calldata o) external onlyKeeperOrOwner {
        if (o.maker != address(this) || o.nft != address(nft)) revert BadParam();
        if (_invIndexPlusOne[o.nftId] == 0) revert NotOwned();
        // Element 语义：erc20TokenAmount 是卖家净收，fees 由买家额外承担。
        // 因此守卫的是「金库净收」，且必须覆盖成本。
        if (o.erc20TokenAmount < minSellNet()) revert PriceTooLow();
        bytes32 h = element.getERC721SellOrderHash(o);
        approvedListings[h] = true;
        nft.setApprovalForAll(address(element), true);
        emit ListingApproved(o.nftId, o.erc20TokenAmount, h);
    }

    function revokeListing(bytes32 h) external onlyKeeperOrOwner { approvedListings[h] = false; }

    function cancelOrder(uint256 nonce) external onlyKeeperOrOwner {
        element.cancelERC721Order(nonce);
        emit OrderCancelled(nonce);
    }

    /// @notice 把闲置的 WBNB 换回 BNB 并回到收购基金（撤单/过期后调用）
    function unwrapIdle() external {
        uint256 bal = wbnb.balanceOf(address(this));
        if (bal > 0) { wbnb.withdraw(bal); nftFund += bal; }
    }

    /// @notice 双向同步库存。Element 用 transferFrom 转 NFT（不触发 onERC721Received），
    ///         所以成交后必须靠这个把账对上。任何人都可以调用。
    function syncInventory(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            bool owned = nft.ownerOf(id) == address(this);
            bool tracked = _invIndexPlusOne[id] != 0;
            if (owned && !tracked) {
                _inventory.push(id);
                _invIndexPlusOne[id] = _inventory.length;
                if (costBasis[id] == 0) costBasis[id] = pendingOrderCost;
                totalBought += 1;
                emit InventoryAdded(id);
            } else if (!owned && tracked) {
                _removeFromInventory(id);
                _onNftLeft(id);
                totalSold += 1;
                emit InventoryRemoved(id);
            }
        }
    }
}
