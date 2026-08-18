// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/// @title NLSTRHook —— $NLSTR / BNB 池子的 v4 钩子
/// @notice 三件事：
///   1. beforeInitialize —— 只允许唯一一个合法池子用这个钩子（原生 BNB / NLSTR / 动态费率）
///   2. beforeAddLiquidity —— **只有金库能加流动性**。金库合约里没有撤出流动性的代码，
///      所以本金被永久锁死，任何人（包括项目方）都取不出来，只能提取手续费。
///   3. beforeSwap —— 动态费率：开盘 95% 线性衰减到 10%，用来烧掉抢跑机器人。
///      **没有任何免税白名单**：项目方、金库、做市商与散户完全同一费率，无法后门减免。
///      因为金库是唯一 LP，这 10% 全额进入金库 → 8% 收购牛来 NFT / 1% 进分红池 / 1% 团队。
///
/// @dev 部署地址必须让低 14 位等于 REQUIRED_FLAGS（v4 用地址位编码钩子权限），需 CREATE2 挖矿。
contract NLSTRHook is IHooks {
    using LPFeeLibrary for uint24;

    /// beforeInitialize | beforeAddLiquidity | beforeSwap = 0x2000 | 0x800 | 0x80
    uint160 public constant REQUIRED_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    uint24 public constant LAUNCH_FEE_PIPS = 950_000; // 95%
    uint24 public constant FINAL_FEE_PIPS = 100_000;  // 10%
    uint24 public constant MIN_FINAL_FEE_PIPS = 10_000; // 团队后续只能往下调，且不低于 1%

    IPoolManager public immutable poolManager;
    address public immutable nlstr;
    address public immutable treasury;

    /// 开盘时间（池子 initialize 的区块时间），衰减基准
    uint256 public launchTime;
    /// 衰减时长（秒）
    uint256 public immutable decaySeconds;
    /// 衰减结束后的固定费率，只允许 owner 调低（owner = treasury）
    uint24 public finalFeePips = FINAL_FEE_PIPS;
    /// 已初始化的池子（只允许一个）
    bool public initialized;
    /// 开盘保护：衰减期内单笔买入上限（wei），0 = 不限制
    uint256 public launchMaxBuy;


    error NotPoolManager();
    error PoolNotAllowed();
    error LiquidityLocked();
    error AlreadyInitialized();
    error NotTreasury();
    error FeeTooHigh();
    error HookNotImplemented();
    error BuyTooLarge();

    event Launched(uint256 timestamp);
    event FinalFeeUpdated(uint24 pips);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _nlstr, address _treasury, uint256 _decaySeconds, uint256 _launchMaxBuy) {
        poolManager = _poolManager;
        nlstr = _nlstr;
        treasury = _treasury;
        decaySeconds = _decaySeconds;
        launchMaxBuy = _launchMaxBuy;
        // 自检：部署地址必须带上正确的权限位，否则 v4 会拒绝
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != REQUIRED_FLAGS) revert PoolNotAllowed();
    }

    // ---------------------------------------------------------------- 费率

    /// @notice 当前费率（pips，1_000_000 = 100%）
    function currentFeePips() public view returns (uint24) {
        uint256 t = launchTime;
        if (t == 0) return LAUNCH_FEE_PIPS;
        uint256 elapsed = block.timestamp - t;
        if (elapsed >= decaySeconds) return finalFeePips;
        uint256 span = LAUNCH_FEE_PIPS - finalFeePips;
        return uint24(LAUNCH_FEE_PIPS - (span * elapsed) / decaySeconds);
    }

    /// @notice 只能调低，且不低于 1%（防止项目方事后加税）
    function setFinalFee(uint24 pips) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (pips >= finalFeePips || pips < MIN_FINAL_FEE_PIPS) revert FeeTooHigh();
        finalFeePips = pips;
        emit FinalFeeUpdated(pips);
    }

    // ---------------------------------------------------------------- 钩子

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        // 只允许：currency0 = 原生 BNB，currency1 = NLSTR，动态费率
        if (!key.currency0.isAddressZero()) revert PoolNotAllowed();
        if (Currency.unwrap(key.currency1) != nlstr) revert PoolNotAllowed();
        if (!key.fee.isDynamicFee()) revert PoolNotAllowed();
        initialized = true;
        launchTime = block.timestamp;
        emit Launched(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        // 只有金库能加流动性；金库没有撤出流动性的函数 → LP 永久锁死
        if (sender != treasury) revert LiquidityLocked();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 开盘保护：衰减期内限制单笔买入规模，防止一笔巨单吃掉大半供应
        uint256 cap = launchMaxBuy;
        if (cap != 0 && launchTime != 0 && block.timestamp < launchTime + decaySeconds) {
            if (params.zeroForOne && params.amountSpecified < 0 && uint256(-params.amountSpecified) > cap) {
                revert BuyTooLarge();
            }
        }
        // 覆盖本次 swap 的 LP 费率；金库是唯一 LP，所以这笔费用 100% 归金库
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            currentFeePips() | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ---------------------------------------------------------------- 未启用的钩子

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }

    function afterRemoveLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external pure returns (bytes4, int128) { revert HookNotImplemented(); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
}
