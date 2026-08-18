// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {NLSTR} from "../src/NLSTR.sol";
import {NLSTRHook} from "../src/NLSTRHook.sol";
import {StrategyTreasury} from "../src/StrategyTreasury.sol";
import {IElementEx, IWBNB} from "../src/ElementTypes.sol";

/// 一键部署牛来永动机。BSC 主网地址已写死。
///   forge script script/Deploy.s.sol:Deploy --rpc-url bsc --broadcast -vvvv
contract Deploy is Script {
    // ---- BSC 主网
    IPoolManager constant PM = IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF);
    IERC721 constant NIULAI_NFT = IERC721(0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D);
    address constant DIVIDEND_VAULT = 0x311188bef22479edE7bd29b61a7aE7D84bA6B55C;
    IElementEx constant ELEMENT = IElementEx(0xb3e3DfCb2d9f3DdE16d78B9e6EB3538Eb32B5ae1);
    IWBNB constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ---- 发行参数
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LP_BPS = 8000;        // 80% 单边入池（永久锁死）
    uint256 constant AIRDROP_BPS = 1000;   // 10% 空投给 999 枚 NFT 的持有者
    uint256 constant DEV_BPS = 1000;       // 10% dev
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_UPPER = 189_300;   // 开盘 FDV ≈ 6 BNB
    int24 constant TICK_LOWER = -887_220;  // 最低可用 tick → 无 FDV 上限
    uint256 constant DECAY = 300;          // 开盘 95% → 10%，5 分钟
    uint256 constant LAUNCH_MAX_BUY = 0.5 ether;

    // 用状态变量而非局部变量，避开 stack too deep
    NLSTR public nlstr;
    NLSTRHook public hook;
    StrategyTreasury public treasury;
    bytes32 public hookSalt;
    address public dev;
    address public team;
    address public airdropHolder;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address owner = vm.addr(pk);
        dev = vm.envOr("DEV_WALLET", owner);
        team = vm.envOr("TEAM_WALLET", owner);
        airdropHolder = vm.envOr("AIRDROP_WALLET", owner);

        vm.startBroadcast(pk);
        _deploy(owner);
        _initPool();
        _seedLiquidity();
        _allocate();
        treasury.setMarketConfig(vm.envOr("MAX_BID", uint256(2 ether)), 200, 13_500);
        vm.stopBroadcast();
        _report();
    }

    function _deploy(address owner) internal {
        nlstr = new NLSTR(owner, SUPPLY);
        treasury = new StrategyTreasury(PM, NIULAI_NFT, DIVIDEND_VAULT, team, owner, ELEMENT, WBNB);
        treasury.setNlstr(address(nlstr));

        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(NLSTRHook).creationCode,
            abi.encode(PM, address(nlstr), address(treasury), DECAY, LAUNCH_MAX_BUY)
        );
        hookSalt = salt;
        hook = new NLSTRHook{salt: salt}(PM, address(nlstr), address(treasury), DECAY, LAUNCH_MAX_BUY);
        require(address(hook) == hookAddr, "hook addr mismatch");
        treasury.setHook(address(hook));
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(nlstr)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _initPool() internal {
        treasury.setPoolKey(poolKey());
        PM.initialize(poolKey(), TickMath.getSqrtPriceAtTick(TICK_UPPER));
    }

    /// 单边注入 80%：一分 BNB 不用出，且金库没有撤出流动性的函数 → 永久锁死
    function _seedLiquidity() internal {
        uint256 lpAmount = SUPPLY * LP_BPS / 10_000;
        nlstr.transfer(address(treasury), lpAmount);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), lpAmount
        );
        treasury.addLiquidity(TICK_LOWER, TICK_UPPER, liq);
    }

    /// 10% 空投池 + 10% dev
    function _allocate() internal {
        nlstr.transfer(airdropHolder, SUPPLY * AIRDROP_BPS / 10_000);
        if (dev != airdropHolder) nlstr.transfer(dev, SUPPLY * DEV_BPS / 10_000);
    }

    function _report() internal view {
        console2.log("NLSTR      ", address(nlstr));
        console2.log("Hook       ", address(hook));
        console2.log("Treasury   ", address(treasury));
        console2.logBytes32(hookSalt);
        console2.log("LP locked  ", (SUPPLY * LP_BPS / 10_000) / 1e18);
        console2.log("airdrop 10%", airdropHolder);
        console2.log("dev 10%    ", dev);
        console2.log("minMarkup  ", treasury.minMarkupBps());
    }
}
