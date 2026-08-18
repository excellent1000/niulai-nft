// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

import {NLSTR} from "../src/NLSTR.sol";
import {NLSTRHook} from "../src/NLSTRHook.sol";
import {StrategyTreasury} from "../src/StrategyTreasury.sol";
import {IElementEx, IWBNB} from "../src/ElementTypes.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// 用 BSC 上真实的 Uniswap Universal Router 买入 —— 这是真实用户走的路径
contract UniversalRouterBuy is Test {
    IPoolManager constant PM = IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF);
    IUniversalRouter constant UR = IUniversalRouter(0x1906c1d672b88cD1B9aC7593301cA990F94Eae07);
    IERC721 constant NFT = IERC721(0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D);
    address constant DIVIDEND_VAULT = 0x311188bef22479edE7bd29b61a7aE7D84bA6B55C;
    IElementEx constant ELEMENT = IElementEx(0xb3e3DfCb2d9f3DdE16d78B9e6EB3538Eb32B5ae1);
    IWBNB constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    int24 constant TICK_UPPER = 189_300;
    int24 constant TICK_LOWER = -887_220;
    uint256 constant DECAY = 300;

    NLSTR nlstr; NLSTRHook hook; StrategyTreasury treasury; PoolKey key;
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        nlstr = new NLSTR(address(this), SUPPLY);
        treasury = new StrategyTreasury(PM, NFT, DIVIDEND_VAULT, makeAddr("team"), address(this), ELEMENT, WBNB);
        treasury.setNlstr(address(nlstr));
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(NLSTRHook).creationCode,
            abi.encode(PM, address(nlstr), address(treasury), DECAY, uint256(0.5 ether)));
        hook = new NLSTRHook{salt: salt}(PM, address(nlstr), address(treasury), DECAY, 0.5 ether);
        treasury.setHook(address(hook));
        key = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(nlstr)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        treasury.setPoolKey(key);
        PM.initialize(key, TickMath.getSqrtPriceAtTick(TICK_UPPER));
        uint256 lp = SUPPLY * 80 / 100;
        nlstr.transfer(address(treasury), lp);
        treasury.addLiquidity(TICK_LOWER, TICK_UPPER, LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), lp));
        vm.deal(user, 100 ether);
    }

    function test_realUserBuysThroughUniversalRouter() public {
        vm.warp(block.timestamp + DECAY + 1);   // 进入 10% 常态
        uint256 amountIn = 1 ether;

        bytes memory commands = abi.encodePacked(uint8(0x10)); // V4_SWAP
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams({
            poolKey: key, zeroForOne: true, amountIn: uint128(amountIn),
            amountOutMinimum: 0, minHopPriceX36: 0, hookData: ""
        }));
        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.prank(user);
        try UR.execute{value: amountIn}(commands, inputs, block.timestamp + 60) {
            uint256 got = nlstr.balanceOf(user);
            console2.log(unicode"✅ 通过真实 Universal Router 买入成功");
            console2.log(unicode"   花 1 BNB 拿到 NLSTR(万枚)", got / 1e22);
            assertGt(got, 0);
            // 手续费应确实进了金库的 LP
            treasury.collectFees(TICK_LOWER, TICK_UPPER);
            console2.log(unicode"   金库收到手续费 → 收购基金(wei)", treasury.nftFund());
            assertGt(treasury.nftFund(), 0.07 ether, unicode"应收到约 0.08 BNB（1 BNB 的 10% 的 80%）");
        } catch Error(string memory e) {
            console2.log(unicode"❌ Universal Router 买入失败:", e);
            fail();
        } catch (bytes memory raw) {
            console2.log(unicode"❌ Universal Router revert:");
            console2.logBytes(raw);
            fail();
        }
    }
}
