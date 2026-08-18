// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

struct Fee { address recipient; uint256 amount; bytes feeData; }
struct NFTSellOrder {
    address maker; address taker; uint256 expiry; uint256 nonce;
    address erc20Token; uint256 erc20TokenAmount; Fee[] fees;
    address nft; uint256 nftId;
}
struct Signature { uint8 signatureType; uint8 v; bytes32 r; bytes32 s; }

interface IElementEx {
    function validateERC721SellOrderSignature(NFTSellOrder calldata order, Signature calldata sig) external view;
    function getERC721SellOrderHash(NFTSellOrder calldata order) external view returns (bytes32);
}

/// 一个"永远同意"的 ERC-1271 合约签名者
contract MockSigner {
    bool public called;
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract ElementProbe is Test {
    IElementEx constant EX = IElementEx(0xb3e3DfCb2d9f3DdE16d78B9e6EB3538Eb32B5ae1);
    address constant NIULAI = 0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D;

    function setUp() public { vm.createSelectFork(vm.envString("BSC_RPC_URL")); }

    function _order(address maker) internal pure returns (NFTSellOrder memory o) {
        o.maker = maker;
        o.taker = address(0);
        o.expiry = type(uint32).max;
        o.nonce = 1;
        o.erc20Token = 0x0000000000000000000000000000000000000000; // 原生币约定地址视实现而定
        o.erc20TokenAmount = 1 ether;
        o.fees = new Fee[](0);
        o.nft = NIULAI;
        o.nftId = 1;
    }

    /// 逐个试 signatureType，看哪个会走到 ERC-1271
    function test_whichSignatureTypeAcceptsContract() public {
        MockSigner signer = new MockSigner();
        NFTSellOrder memory o = _order(address(signer));
        for (uint8 t = 0; t < 6; t++) {
            Signature memory s = Signature({signatureType: t, v: 27, r: bytes32(uint256(1)), s: bytes32(uint256(2))});
            try EX.validateERC721SellOrderSignature(o, s) {
                console2.log(unicode"  signatureType", t, unicode"→ 合约签名被接受 ✅");
            } catch Error(string memory reason) {
                console2.log(unicode"  signatureType", t, reason);
            } catch (bytes memory) {
                console2.log(unicode"  signatureType", t, unicode"→ revert(无原因)");
            }
        }
    }

    /// 顺便确认 EOA 的正常签名路径能过（验证我们对结构体的猜测是对的）
    function test_eoaSignatureWorks() public {
        (address eoa, uint256 pk) = makeAddrAndKey("eoa");
        NFTSellOrder memory o = _order(eoa);
        bytes32 h;
        try EX.getERC721SellOrderHash(o) returns (bytes32 hh) { h = hh; console2.log(unicode"订单哈希可取 ✅"); }
        catch { console2.log(unicode"getERC721SellOrderHash 不可用（未被代理路由）"); return; }
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, h);
        for (uint8 t = 0; t < 6; t++) {
            try EX.validateERC721SellOrderSignature(o, Signature(t, v, r, s_)) {
                console2.log(unicode"  EOA signatureType", t, unicode"→ 通过 ✅");
            } catch { }
        }
    }
}
