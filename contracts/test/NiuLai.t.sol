// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {NiuLai} from "../src/NiuLai.sol";
import {NiuLaiVault} from "../src/NiuLaiVault.sol";
import {MockToken, MockWBNB, MockRouter, MockValidator, Rejector} from "./Mocks.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ICreatorToken} from "../src/interfaces/IExternal.sol";

contract NiuLaiTest is Test {
    NiuLai nft;
    NiuLaiVault vault;
    MockToken token;
    MockWBNB wbnb;
    MockRouter router;

    address owner = makeAddr("owner");
    address payable treasury = payable(makeAddr("treasury"));
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address escrow = makeAddr("escrow"); // 模拟市场托管合约

    uint256 constant PRICE = 1000 ether; // 1000 枚 $牛来

    function setUp() public {
        token = new MockToken();
        wbnb = new MockWBNB();
        router = new MockRouter(token, 1_000_000 ether); // 1 BNB = 1,000,000 牛来
        vm.startPrank(owner);
        nft = new NiuLai(owner, address(token), treasury, "https://niulai.example/meta/");
        bytes memory path = abi.encodePacked(address(wbnb), uint24(100), address(0xDEAD), uint24(10000), address(token));
        vault = new NiuLaiVault(owner, address(token), address(wbnb), address(nft), address(router), path);
        nft.setVault(address(vault));
        nft.setRoyalty(address(vault), 1000);
        nft.setSaleState(true, false);
        vault.setKeeper(keeper, true);
        vm.stopPrank();
        // 给买家发 $牛来 并授权
        for (uint256 i = 0; i < 4; i++) {
            address who = [alice, bob, carol, escrow][i];
            token.mint(who, 1_000_000 ether);
            vm.prank(who);
            token.approve(address(nft), type(uint256).max);
        }
    }

    // ---------- 铸造 ----------

    function test_mint_basic() public {
        vm.prank(alice);
        nft.mint(3);
        assertEq(nft.totalSupply(), 3);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(3), alice);
        assertEq(nft.minted(alice), 3);
        assertEq(token.balanceOf(treasury), PRICE * 3);
    }

    function test_mint_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(NiuLai.BadQuantity.selector);
        nft.mint(6);
        nft.mint(5);
        vm.expectRevert(NiuLai.WalletLimit.selector);
        nft.mint(1);
        vm.stopPrank();
        vm.prank(owner);
        nft.setSaleState(false, false);
        vm.prank(bob);
        vm.expectRevert(NiuLai.SaleClosed.selector);
        nft.mint(1);
    }

    function test_reserve_protected_and_soldout() public {
        token.mint(alice, 2_000_000 ether);
        vm.prank(owner);
        nft.setSaleConfig(PRICE, PRICE, 10_000, 500);
        // 公售最多 999-30 = 969
        vm.startPrank(alice);
        nft.mint(500);
        nft.mint(469);
        assertEq(nft.totalSupply(), 969);
        vm.expectRevert(NiuLai.SoldOut.selector);
        nft.mint(1);
        vm.stopPrank();
        vm.prank(owner);
        nft.reserveMint(treasury, 30);
        assertEq(nft.totalSupply(), 999);
        assertEq(nft.ownerOf(999), treasury);
        vm.prank(owner);
        vm.expectRevert(NiuLai.BadQuantity.selector);
        nft.reserveMint(treasury, 1);
    }

    function test_allowlist() public {
        // 单叶子树：root = leaf
        bytes32 leaf = keccak256(abi.encodePacked(alice));
        vm.startPrank(owner);
        nft.setMerkleRoot(leaf);
        nft.setSaleState(false, true);
        vm.stopPrank();
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        nft.allowlistMint(1, proof);
        assertEq(nft.ownerOf(1), alice);
        vm.prank(bob);
        vm.expectRevert(NiuLai.NotAllowlisted.selector);
        nft.allowlistMint(1, proof);
    }

    function test_mint_split() public {
        vm.prank(owner);
        nft.setMintSplit(5000, 3000, 2000); // 50% 国库 / 30% 金库 / 20% 销毁
        vm.prank(alice);
        nft.mint(2);
        assertEq(token.balanceOf(treasury), PRICE * 2 * 5000 / 10_000);
        assertEq(token.balanceOf(address(vault)), PRICE * 2 * 3000 / 10_000);
        assertEq(token.balanceOf(nft.BURN()), PRICE * 2 * 2000 / 10_000);
        vm.prank(owner);
        vm.expectRevert(NiuLai.BadQuantity.selector);
        nft.setMintSplit(5000, 3000, 1000);
        // 没授权/余额不足 → 失败
        address dave = makeAddr("dave");
        vm.prank(dave);
        vm.expectRevert();
        nft.mint(1);
    }

    function test_mint_proceeds_to_vault_join_next_round() public {
        vm.prank(owner);
        nft.setMintSplit(0, 10_000, 0); // 全部进金库
        vm.prank(alice);
        nft.mint(4); // 4000 牛来 进金库
        vm.deal(address(vault), 1 ether);
        vm.prank(keeper);
        uint256 out = vault.harvest(0);
        assertEq(vault.roundAmount(), out + PRICE * 4); // 铸造收入并入本轮
        vault.distribute(10);
        assertEq(token.balanceOf(alice), 1_000_000 ether - PRICE * 4 + (out + PRICE * 4) / 4 * 4);
    }

    // ---------- 元数据 / 版税 ----------

    function test_metadata_and_royalty() public {
        vm.prank(alice);
        nft.mint(1);
        assertEq(nft.tokenURI(1), "https://niulai.example/meta/1.json"); // 实时 reveal
        vm.startPrank(owner);
        nft.setRevealed(false);
        nft.setUnrevealedURI("ipfs://unrevealed.json");
        assertEq(nft.tokenURI(1), "ipfs://unrevealed.json");
        nft.reveal("ipfs://QmMeta/");
        vm.stopPrank();
        assertEq(nft.tokenURI(1), "ipfs://QmMeta/1.json");
        (address recv, uint256 amt) = nft.royaltyInfo(1, 1 ether);
        assertEq(recv, address(vault));
        assertEq(amt, 0.1 ether);
        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(nft.supportsInterface(type(ICreatorToken).interfaceId));
        vm.prank(owner);
        vm.expectRevert(NiuLai.RoyaltyTooHigh.selector);
        nft.setRoyalty(address(vault), 1001);
    }

    function test_transfer_validator_hook() public {
        vm.prank(alice);
        nft.mint(1);
        MockValidator v = new MockValidator(bob); // bob 作为操作者被拉黑
        vm.prank(owner);
        nft.setTransferValidator(address(v));
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert("operator blocked");
        nft.transferFrom(alice, carol, 1);
        vm.prank(alice);
        nft.transferFrom(alice, carol, 1); // 持有人自己转没问题
        assertEq(nft.ownerOf(1), carol);
    }

    // ---------- 金库：买入 + 自动分发 ----------

    function _mintTo(address who, uint32 qty) internal {
        vm.prank(who);
        nft.mint(qty);
    }

    function test_harvest_and_distribute() public {
        _mintTo(alice, 3); // 1,2,3
        _mintTo(bob, 2);   // 4,5
        _mintTo(carol, 5); // 6..10
        // 模拟版税进账：8 BNB + 2 WBNB
        vm.deal(address(vault), 8 ether);
        vm.deal(address(this), 2 ether);
        wbnb.deposit{value: 2 ether}();
        wbnb.transfer(address(vault), 2 ether);

        (bool ready,,) = vault.canHarvest();
        assertTrue(ready);
        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        uint256 out = vault.harvest(0);
        // 10 BNB，0.5% 给 keeper → 9.95 BNB 买入
        assertEq(keeper.balance, 0.05 ether);
        assertEq(out, 9_950_000 ether);
        assertEq(token.balanceOf(address(vault)), out);
        assertTrue(vault.roundActive());
        assertEq(vault.roundSupply(), 10);
        assertEq(vault.roundShare(), out / 10);

        // 分两批发：先 4 个（1..4），再剩下
        uint256 a0 = token.balanceOf(alice); uint256 b0 = token.balanceOf(bob); uint256 c0 = token.balanceOf(carol);
        vault.distribute(4);
        assertEq(token.balanceOf(alice) - a0, out / 10 * 3);
        assertEq(token.balanceOf(bob) - b0, out / 10 * 1);
        assertEq(vault.cursor(), 4);
        assertTrue(vault.roundActive());
        vault.distribute(100);
        assertEq(token.balanceOf(bob) - b0, out / 10 * 2);
        assertEq(token.balanceOf(carol) - c0, out / 10 * 5);
        assertFalse(vault.roundActive());
        assertEq(vault.totalTokenDistributed(), out / 10 * 10);
        // 没有轮次时不能分
        vm.expectRevert(NiuLaiVault.NoRound.selector);
        vault.distribute(1);
    }

    function test_harvest_gating() public {
        _mintTo(alice, 1);
        vm.deal(address(vault), 1 ether);
        // 非 keeper 不能 harvest
        vm.prank(bob);
        vm.expectRevert(NiuLaiVault.NotKeeper.selector);
        vault.harvest(0);
        // 太小
        vm.deal(address(vault), 0.001 ether);
        vm.prank(keeper);
        vm.expectRevert(NiuLaiVault.TooSmall.selector);
        vault.harvest(0);
        // 正常
        vm.deal(address(vault), 1 ether);
        vm.prank(keeper);
        vault.harvest(0);
        vault.distribute(10);
        // 一小时内不能再来
        vm.deal(address(vault), 1 ether);
        vm.prank(keeper);
        vm.expectRevert(NiuLaiVault.TooEarly.selector);
        vault.harvest(0);
        // owner 不受间隔限制
        vm.prank(owner);
        vault.harvest(0);
        // 轮次未发完不能 harvest
        vm.deal(address(vault), 1 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(keeper);
        vm.expectRevert(NiuLaiVault.RoundInProgress.selector);
        vault.harvest(0);
        // minOut 保护
        vault.distribute(10);
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        vault.harvest(type(uint256).max);
        // 公开 harvest 开关
        vm.prank(owner);
        vault.setPublicHarvest(true);
        vm.prank(bob);
        vault.harvest(0);
    }

    function test_excluded_share_stays_and_rolls_over() public {
        _mintTo(alice, 2);
        vm.deal(escrow, 1 ether);
        _mintTo(escrow, 2); // 托管地址持有 3,4
        vm.prank(owner);
        vault.setExcluded(escrow, true);
        vm.deal(address(vault), 4 ether);
        uint256 a0 = token.balanceOf(alice); uint256 e0 = token.balanceOf(escrow);
        vm.prank(keeper);
        uint256 out = vault.harvest(0);
        vault.distribute(10);
        uint256 share = out / 4;
        assertEq(token.balanceOf(alice) - a0, share * 2);
        assertEq(token.balanceOf(escrow) - e0, 0);
        assertEq(token.balanceOf(address(vault)), share * 2); // 留在金库
        assertEq(vault.totalSkipped(), share * 2);
        // 下一轮把剩余并入
        vm.warp(block.timestamp + 1 hours);
        vm.deal(address(vault), 4 ether);
        vm.prank(keeper);
        uint256 out2 = vault.harvest(0);
        assertEq(vault.roundAmount(), out2 + share * 2);
    }

    function test_donate_and_dust() public {
        _mintTo(alice, 3);
        token.mint(owner, 1000);
        vm.startPrank(owner);
        token.approve(address(vault), 1000);
        vault.donate(1000);
        vm.stopPrank();
        // 非 keeper 不能 donate
        token.mint(bob, 1000);
        vm.startPrank(bob);
        token.approve(address(vault), 1000);
        vm.expectRevert(NiuLaiVault.NotKeeper.selector);
        vault.donate(1000);
        vm.stopPrank();
        assertEq(vault.roundShare(), 333);
        vault.distribute(3);
        assertEq(token.balanceOf(alice), 1_000_000 ether - PRICE * 3 + 999);
        assertEq(token.balanceOf(address(vault)), 1); // 尾数留下
    }

    function test_distribute_gas_999_holders() public {
        // 999 个不同持有人，最坏情况：每个 tokenId 一次转账
        vm.prank(owner);
        nft.setSaleConfig(PRICE, PRICE, 10_000, 1000);
        vm.prank(owner);
        nft.setReserve(0);
        for (uint256 i = 1; i <= 999; i++) {
            address h = address(uint160(0x100000 + i));
            token.mint(h, PRICE);
            vm.startPrank(h);
            token.approve(address(nft), PRICE);
            nft.mint(1);
            vm.stopPrank();
        }
        vm.deal(address(vault), 10 ether);
        vm.prank(keeper);
        vault.harvest(0);
        uint256 g0 = gasleft();
        vault.distribute(250);
        uint256 used = g0 - gasleft();
        console2.log("distribute(250) gas, 250 unique holders:", used);
        assertLt(used, 15_000_000);
        vault.distribute(250);
        vault.distribute(250);
        vault.distribute(250);
        assertFalse(vault.roundActive());
        assertEq(token.balanceOf(address(uint160(0x100000 + 999))), vault.roundShare());
    }

    function test_distribute_gas_aggregated() public {
        // 同一持有人拿很多枚：聚合后只转一次
        vm.prank(owner);
        nft.setSaleConfig(PRICE, PRICE, 10_000, 1000);
        _mintTo(alice, 250); // alice 有 100 万牛来，够 250 枚
        vm.deal(address(vault), 10 ether);
        vm.prank(keeper);
        vault.harvest(0);
        uint256 g0 = gasleft();
        vault.distribute(250);
        uint256 used = g0 - gasleft();
        console2.log("distribute(250) gas, 1 holder:", used);
        assertLt(used, 3_000_000);
    }

    function test_harvest_erc20_royalty() public {
        // 市场用 USDT 结算的版税：USDT 进金库 → harvestToken 换成 牛来 → 分发
        MockToken usdt = new MockToken();
        _mintTo(alice, 2);
        usdt.mint(address(vault), 500 ether);
        bytes memory path = abi.encodePacked(address(usdt), uint24(10000), address(token));
        vm.prank(bob);
        vm.expectRevert(NiuLaiVault.NotKeeper.selector);
        vault.harvestToken(address(usdt), 0);
        vm.prank(keeper);
        vm.expectRevert(NiuLaiVault.BadParam.selector); // 未配置路径
        vault.harvestToken(address(usdt), 0);
        vm.prank(owner);
        vault.setTokenSwapPath(address(usdt), path);
        uint256 a0 = token.balanceOf(alice);
        vm.prank(keeper);
        uint256 out = vault.harvestToken(address(usdt), 0);
        assertEq(out, 500 ether * 1_000_000); // mock 汇率
        assertEq(usdt.balanceOf(address(vault)), 0);
        vault.distribute(10);
        assertEq(token.balanceOf(alice) - a0, out / 2 * 2);
        // 不能对 $牛来 / WBNB 本身调用
        vm.prank(owner);
        vm.expectRevert(NiuLaiVault.BadParam.selector);
        vault.harvestToken(address(token), 0);
    }

    function test_rescue_and_admin() public {
        vm.prank(owner);
        vm.expectRevert(NiuLaiVault.BadParam.selector);
        vault.rescueToken(address(token), owner, 1);
        vm.prank(owner);
        vm.expectRevert(NiuLaiVault.BadParam.selector);
        vault.setRewards(501, 0);
        vm.prank(owner);
        vault.setRewards(100, 0.001 ether);
        assertEq(vault.callerRewardBps(), 100);
    }

    receive() external payable {}
}
