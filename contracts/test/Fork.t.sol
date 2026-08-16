// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {NiuLai} from "../src/NiuLai.sol";
import {NiuLaiVault} from "../src/NiuLaiVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// BSC 主网 fork：真实 PancakeSwap V3 router、真实 牛来/USDT 池。
///   forge test --match-contract ForkTest --fork-url https://bsc-dataseed.binance.org -vv
contract ForkTest is Test {
    address constant TOKEN = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    function test_fork_harvest_real_router() public {
        if (block.chainid != 56) {
            console2.log("skip: not a BSC fork");
            return;
        }
        address owner = vm.addr(0x0A11E2);
        address alice = vm.addr(0xA11CE1);
        vm.deal(alice, 10 ether);
        vm.startPrank(owner);
        NiuLai nft = new NiuLai(owner, TOKEN, owner, "https://niulai.example/meta/");
        bytes memory path = abi.encodePacked(WBNB, uint24(100), USDT, uint24(10000), TOKEN);
        NiuLaiVault vault = new NiuLaiVault(owner, TOKEN, WBNB, address(nft), ROUTER, path);
        nft.setVault(address(vault));
        nft.setRoyalty(address(vault), 1000);
        nft.setSaleState(true, false);
        vm.stopPrank();

        // 给 alice 一些真实的 $牛来（用 anvil/forge 的 deal 直接改余额）
        deal(TOKEN, alice, 10_000 ether);
        vm.startPrank(alice);
        IERC20(TOKEN).approve(address(nft), type(uint256).max);
        nft.mint(4); // 4000 牛来 → 国库(owner)
        vm.stopPrank();
        assertEq(IERC20(TOKEN).balanceOf(owner), 4000 ether);

        vm.deal(address(vault), 1 ether); // 模拟 1 BNB 版税
        vm.prank(owner);
        uint256 out = vault.harvest(0);
        console2.log("1 BNB ->", out / 1e18, "NIULAI (approx)");
        assertGt(out, 0);
        assertEq(IERC20(TOKEN).balanceOf(address(vault)), out);

        vault.distribute(999);
        assertEq(IERC20(TOKEN).balanceOf(alice), 6000 ether + (out / 4) * 4);
        assertFalse(vault.roundActive());
        console2.log("alice got", IERC20(TOKEN).balanceOf(alice) / 1e18);
    }
}
