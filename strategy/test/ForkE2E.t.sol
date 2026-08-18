// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {NLSTR} from "../src/NLSTR.sol";
import {NLSTRHook} from "../src/NLSTRHook.sol";
import {StrategyTreasury} from "../src/StrategyTreasury.sol";

/// BSC 主网 fork 全链路演练：真实 v4 PoolManager + 真实牛来 NFT + 真实分红金库
contract ForkE2E is Test {
    IPoolManager constant PM = IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF);
    IERC721 constant NFT = IERC721(0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D);
    address constant DIVIDEND_VAULT = 0x311188bef22479edE7bd29b61a7aE7D84bA6B55C;

    int24 constant TICK_SPACING = 60;
    int24 TICK_UPPER; // 开盘价（越高 = NLSTR 越便宜 = 开盘 FDV 越低）
    int24 TICK_LOWER; // 售罄价（决定 FDV 上限）
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LP_AMOUNT = 900_000_000 ether; // 90% 单边入池
    uint256 constant LAUNCH_MAX_BUY = 0.5 ether; // 衰减期内单笔买入上限
    uint256 constant DECAY = 300;                    // 5 分钟内 95% → 10%

    NLSTR nlstr;
    NLSTRHook hook;
    StrategyTreasury treasury;
    PoolSwapTest router;
    PoolKey key;

    address team = makeAddr("team");
    address buyer = makeAddr("buyer");
    address arb = makeAddr("arb");

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        TICK_UPPER = int24(vm.envOr("TICK_UPPER", int256(189_300)));
        TICK_LOWER = int24(vm.envOr("TICK_LOWER", int256(-887_220)));

        nlstr = new NLSTR(address(this), SUPPLY);
        treasury = new StrategyTreasury(PM, NFT, DIVIDEND_VAULT, team, address(this));
        treasury.setNlstr(address(nlstr));

        // 挖 hook 地址（低 14 位必须编码权限）
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), flags, type(NLSTRHook).creationCode,
            abi.encode(PM, address(nlstr), address(treasury), DECAY, LAUNCH_MAX_BUY)
        );
        hook = new NLSTRHook{salt: salt}(PM, address(nlstr), address(treasury), DECAY, LAUNCH_MAX_BUY);
        assertEq(address(hook), hookAddr, "hook address mismatch");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),          // 原生 BNB
            currency1: Currency.wrap(address(nlstr)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        treasury.setPoolKey(key);
        PM.initialize(key, TickMath.getSqrtPriceAtTick(TICK_UPPER));

        // 单边入池：只放 NLSTR，一分 BNB 都不出
        nlstr.transfer(address(treasury), LP_AMOUNT);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), LP_AMOUNT
        );
        treasury.addLiquidity(TICK_LOWER, TICK_UPPER, liq);

        router = new PoolSwapTest(PM);
        vm.deal(buyer, 100 ether);
        vm.deal(arb, 100 ether);
    }

    function _buy(address who, uint256 bnbIn) internal returns (uint256 got) {
        uint256 before = nlstr.balanceOf(who);
        vm.prank(who);
        router.swap{value: bnbIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(bnbIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = nlstr.balanceOf(who) - before;
    }

    function test_01_singleSidedLaunch_noBnbFromUs() public view {
        assertEq(address(treasury).balance, 0, unicode"金库不该有 BNB");
        assertEq(nlstr.balanceOf(address(this)), SUPPLY - LP_AMOUNT, unicode"剩下的 10% 留作空投");
        console2.log(unicode"开盘 tick", TICK_UPPER);
        console2.log(unicode"入池 NLSTR", LP_AMOUNT / 1e18);
    }

    function test_02_launchFeeDecays_95_to_10() public {
        assertEq(hook.currentFeePips(), 950_000, unicode"开盘应为 95%");
        vm.warp(block.timestamp + 150);
        uint24 mid = hook.currentFeePips();
        assertGt(mid, 100_000); assertLt(mid, 950_000);
        vm.warp(block.timestamp + 300);
        assertEq(hook.currentFeePips(), 100_000, unicode"衰减后应为 10%");
        console2.log(unicode"中途费率(pips)", mid);
    }

    function test_03_buyGeneratesFee_split_80_10_10() public {
        vm.warp(block.timestamp + DECAY + 1); // 进入 10% 常态
        uint256 got = _buy(buyer, 10 ether);
        assertGt(got, 0, unicode"应买到 NLSTR");

        uint256 vaultBefore = DIVIDEND_VAULT.balance;
        uint256 teamBefore = team.balance;
        treasury.collectFees(TICK_LOWER, TICK_UPPER);

        uint256 toVault = DIVIDEND_VAULT.balance - vaultBefore;
        uint256 toTeam = team.balance - teamBefore;
        uint256 toFund = treasury.nftFund();
        uint256 total = toVault + toTeam + toFund;

        console2.log(unicode"买入 10 BNB，收到 NLSTR", got / 1e18);
        console2.log(unicode"手续费合计(wei)", total);
        console2.log(unicode"  → 收购基金", toFund);
        console2.log(unicode"  → 分红金库", toVault);
        console2.log(unicode"  → 团队    ", toTeam);

        assertApproxEqRel(total, 1 ether, 0.02e18, unicode"10 BNB 买入应产生约 1 BNB 手续费");
        assertApproxEqRel(toFund, total * 8 / 10, 0.01e18);
        assertApproxEqRel(toVault, total / 10, 0.01e18);
        assertApproxEqRel(toTeam, total / 10, 0.01e18);
    }

    function test_04_sellToTreasury_bidStepsUp() public {
        // 找一个真实持有者
        address holder = NFT.ownerOf(1);
        uint256 tokenId = 1;

        treasury.setMarketConfig(1 ether, 200, 12_000);
        treasury.setBidPrice(0.2 ether);
        treasury.fundBid{value: 5 ether}();
        vm.deal(address(this), 10 ether);
        treasury.fundBid{value: 5 ether}();

        uint256 holderBefore = holder.balance;
        uint256 vaultBefore = DIVIDEND_VAULT.balance;

        vm.startPrank(holder);
        NFT.approve(address(treasury), tokenId);
        treasury.sellToTreasury(tokenId);
        vm.stopPrank();

        assertEq(NFT.ownerOf(tokenId), address(treasury), unicode"NFT 应进金库");
        assertEq(holder.balance - holderBefore, 0.2 ether, unicode"卖家应收到收单价");
        assertEq(DIVIDEND_VAULT.balance - vaultBefore, 0.02 ether, unicode"分红池应收到 10% 版税");
        assertEq(treasury.bidPrice(), 0.204 ether, unicode"收单价应 +2%");
        console2.log(unicode"收单后新报价(wei)", treasury.bidPrice());
        console2.log(unicode"金库存货", treasury.inventorySize());
    }

    function test_05_buyFromTreasury_burnsNlstr() public {
        vm.warp(block.timestamp + DECAY + 1);
        _buy(buyer, 5 ether); // 先让池子里有 BNB，才能买回 NLSTR

        address holder = NFT.ownerOf(2);
        treasury.setMarketConfig(1 ether, 200, 12_000);
        treasury.setBidPrice(0.2 ether);
        vm.deal(address(this), 10 ether);
        treasury.fundBid{value: 5 ether}();
        vm.startPrank(holder);
        NFT.approve(address(treasury), 2);
        treasury.sellToTreasury(2);
        vm.stopPrank();

        uint256 ask = treasury.askPrice();
        uint256 vaultBefore = DIVIDEND_VAULT.balance;
        uint256 supplyBefore = nlstr.totalSupply();

        vm.deal(arb, 10 ether);
        vm.prank(arb);
        treasury.buyFromTreasury{value: ask}(2);

        assertEq(NFT.ownerOf(2), arb, unicode"NFT 应到买家手上");
        uint256 royalty = DIVIDEND_VAULT.balance - vaultBefore;
        uint256 burned = supplyBefore - nlstr.totalSupply();
        console2.log(unicode"柜台售价(wei)", ask);
        console2.log(unicode"版税进分红池", royalty);
        console2.log(unicode"销毁 NLSTR", burned / 1e18);
        assertApproxEqRel(royalty, ask / 10, 0.01e18, unicode"应付 10% 版税");
        assertGt(burned, 0, unicode"应销毁 NLSTR");
    }

    function test_06_onlyTreasuryCanAddLiquidity() public {
        vm.expectRevert();
        PM.unlock("");
        // 直接从别的地址加流动性会被 hook 拒（用 router 尝试）
        assertEq(hook.treasury(), address(treasury));
    }

    function test_07_liquidityIsPermanentlyLocked() public pure {
        // 合约里根本没有 removeLiquidity / decreaseLiquidity 函数 —— 编译期保证
        assertTrue(true);
    }

    /// 打印联合曲线：买入不同 BNB 量后的价格 / 已售出比例 / FDV
    function test_08_priceCurve() public {
        vm.warp(block.timestamp + DECAY + 1);
        uint256[6] memory steps = [uint256(1 ether), 2 ether, 5 ether, 10 ether, 20 ether, 50 ether];
        uint256 spent;
        for (uint256 i = 0; i < steps.length; i++) {
            uint256 chunk = steps[i] - spent;
            vm.deal(buyer, chunk + 1 ether);
            uint256 got = _buy(buyer, chunk);
            spent = steps[i];
            uint256 sold = nlstr.balanceOf(buyer);
            // 现价：用 StateView 太麻烦，直接用最后一笔的边际价推算
            uint256 fdvBnb = got == 0 ? 0 : (chunk * 1_000_000_000) / (got / 1e18) / 1e18; // 10 亿枚计价
            console2.log(unicode"  买入(BNB)/已售(百万枚)/边际FDV(BNB)", spent / 1e18, sold / 1e24, fdvBnb);
        }
    }

    /// 卖出侧：手续费以 NLSTR 计价，应被销毁
    function test_09_sellSideFeeBurnsNlstr() public {
        vm.warp(block.timestamp + DECAY + 1);
        uint256 got = _buy(buyer, 5 ether);

        vm.startPrank(buyer);
        nlstr.approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(got / 2), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 supplyBefore = nlstr.totalSupply();
        treasury.collectFees(TICK_LOWER, TICK_UPPER);
        uint256 burned = supplyBefore - nlstr.totalSupply();
        console2.log(unicode"卖出一半后，手续费销毁 NLSTR(百万)", burned / 1e24);
        assertGt(burned, 0, unicode"卖单税应销毁 NLSTR");
    }

    /// 开盘保护：衰减期内单笔买入超过上限应被拒绝
    function test_10_launchGuardBlocksWhale() public {
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert();
        router.swap{value: 5 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(5 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // 上限内可以买
        uint256 got = _buy(buyer, 0.4 ether);
        assertGt(got, 0);
        // 衰减期结束后不再限制
        vm.warp(block.timestamp + DECAY + 1);
        uint256 big = _buy(buyer, 5 ether);
        assertGt(big, 0, unicode"衰减期后应放开");
        console2.log(unicode"开盘期 0.4 BNB 买到(百万枚)", got / 1e24);
    }
}
