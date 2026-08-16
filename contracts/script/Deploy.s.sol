// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NiuLai} from "../src/NiuLai.sol";
import {NiuLaiVault} from "../src/NiuLaiVault.sol";

/// 用法（.env 里配 DEPLOYER_PK / TREASURY / KEEPER / BSC_RPC_URL / BSCSCAN_API_KEY）：
///   forge script script/Deploy.s.sol:Deploy --rpc-url bsc --broadcast --verify -vvvv
/// 主网常量（BSC）：
///   $牛来      0xbeea1d618e533a387d941f58a7d4c9b7bd377777
///   WBNB       0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
///   USDT       0x55d398326f99059fF775485246999027B3197955
///   Pancake V3 SwapRouter 0x1b81D678ffb9C0263b24A97847620C99d213eB14
///   路径：WBNB -(0.01%)-> USDT -(1%)-> 牛来  （牛来/USDT 主池 0xab058332…1759 是 1% 档）
contract Deploy is Script {
    address constant TOKEN = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        address payable treasury = payable(vm.envOr("TREASURY", deployer));
        address keeper = vm.envOr("KEEPER", deployer);
        string memory baseURI = vm.envOr("BASE_URI", string("https://REPLACE_ME/meta/"));
        uint256 price = vm.envOr("MINT_PRICE", uint256(1000 ether));          // 1000 枚 $牛来
        uint256 alPrice = vm.envOr("ALLOWLIST_PRICE", uint256(800 ether));
        uint16 treasuryBps = uint16(vm.envOr("SPLIT_TREASURY_BPS", uint256(10_000)));
        uint16 vaultBps = uint16(vm.envOr("SPLIT_VAULT_BPS", uint256(0)));
        uint16 burnBps = uint16(vm.envOr("SPLIT_BURN_BPS", uint256(0)));
        uint24 feeWbnbUsdt = uint24(vm.envOr("FEE_WBNB_USDT", uint256(100)));
        uint24 feeUsdtToken = uint24(vm.envOr("FEE_USDT_TOKEN", uint256(10000)));

        bytes memory path = abi.encodePacked(WBNB, feeWbnbUsdt, USDT, feeUsdtToken, TOKEN);

        vm.startBroadcast(pk);
        NiuLai nft = new NiuLai(deployer, TOKEN, treasury, baseURI);
        NiuLaiVault vault = new NiuLaiVault(deployer, TOKEN, WBNB, address(nft), ROUTER, path);
        nft.setVault(address(vault));
        nft.setRoyalty(address(vault), 1000); // 10%
        nft.setSaleConfig(price, alPrice, 5, 5);
        // 市场用 USDT 结算的版税：USDT -(1%)-> 牛来
        vault.setTokenSwapPath(USDT, abi.encodePacked(USDT, feeUsdtToken, TOKEN));
        if (vaultBps > 0 || burnBps > 0) nft.setMintSplit(treasuryBps, vaultBps, burnBps);
        if (keeper != deployer) vault.setKeeper(keeper, true);
        vm.stopBroadcast();

        console2.log("NiuLai  NFT :", address(nft));
        console2.log("NiuLaiVault :", address(vault));
        console2.log("deployer/owner:", deployer);
        console2.log("treasury:", treasury);
        console2.log("keeper:", keeper);
        console2.logBytes(path);
    }
}
