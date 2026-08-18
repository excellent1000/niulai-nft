// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

struct Fee { address recipient; uint256 amount; bytes feeData; }
struct NFTSellOrder {
    address maker; address taker; uint256 expiry; uint256 nonce;
    address erc20Token; uint256 erc20TokenAmount; Fee[] fees;
    address nft; uint256 nftId;
}
struct Signature { uint8 signatureType; uint8 v; bytes32 r; bytes32 s; }

interface IElementEx {
    function buyERC721Ex(NFTSellOrder calldata order, Signature calldata sig, address taker, bytes calldata extraData)
        external payable;
    function validateERC721SellOrderSignature(NFTSellOrder calldata order, Signature calldata sig) external view;
    function getERC721SellOrderHash(NFTSellOrder calldata order) external view returns (bytes32);
}

/// 模拟金库：ERC-1271 授权指定订单哈希
contract MockVault {
    mapping(bytes32 => bool) public approved;
    address public owner;
    constructor() { owner = msg.sender; }
    function approve(bytes32 h) external { approved[h] = true; }
    function isValidSignature(bytes32 h, bytes memory) external view returns (bytes4) {
        return approved[h] ? bytes4(0x1626ba7e) : bytes4(0);
    }
    function setApprovalForAll(address nft, address op) external { IERC721(nft).setApprovalForAll(op, true); }
    receive() external payable {}
}

contract ElementFill is Test {
    IElementEx constant EX = IElementEx(0xb3e3DfCb2d9f3DdE16d78B9e6EB3538Eb32B5ae1);
    IERC721 constant NFT = IERC721(0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D);
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant VAULT_ROYALTY = 0x311188bef22479edE7bd29b61a7aE7D84bA6B55C;

    MockVault vault;
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        vault = new MockVault();
        vm.deal(buyer, 100 ether);
    }

    function _giveNftTo(address to, uint256 tokenId) internal {
        address holder = NFT.ownerOf(tokenId);
        vm.prank(holder);
        NFT.transferFrom(holder, to, tokenId);
    }

    function _order(uint256 tokenId, uint256 price) internal view returns (NFTSellOrder memory o) {
        o.maker = address(vault);
        o.taker = address(0);
        o.expiry = block.timestamp + 7 days;
        o.nonce = 12345;
        o.erc20Token = NATIVE;
        o.erc20TokenAmount = price;
        o.fees = new Fee[](0);
        o.nft = address(NFT);
        o.nftId = tokenId;
    }

    /// 关键验证：合约当 maker，买家通过 Element 合约真实成交
    function test_contractMakerCanSell() public {
        uint256 tokenId = 3;
        uint256 price = 0.3 ether;
        _giveNftTo(address(vault), tokenId);
        vault.setApprovalForAll(address(NFT), address(EX));

        NFTSellOrder memory o = _order(tokenId, price);
        bytes32 h = EX.getERC721SellOrderHash(o);
        vault.approve(h);
        console2.log(unicode"订单哈希已链上授权");

        // 先确认签名校验能过
        for (uint8 t = 3; t <= 4; t++) {
            try EX.validateERC721SellOrderSignature(o, Signature(t, 27, 0, 0)) {
                console2.log(unicode"  sigType 通过校验:", t);
            } catch Error(string memory e) { console2.log(unicode"  sigType 校验失败:", t, e); }
        }

        uint256 vaultBefore = address(vault).balance;
        vm.prank(buyer);
        try EX.buyERC721Ex{value: price}(o, Signature(3, 27, 0, 0), buyer, "") {
            console2.log(unicode"✅ 成交成功");
            console2.log(unicode"   NFT 新主人是买家:", NFT.ownerOf(tokenId) == buyer);
            console2.log(unicode"   金库收到(wei):", address(vault).balance - vaultBefore);
        } catch Error(string memory e) {
            console2.log(unicode"❌ 成交失败:", e);
        } catch (bytes memory raw) {
            console2.log(unicode"❌ 成交 revert(无原因)，前4字节:");
            console2.logBytes(raw);
        }
    }

    /// 带版税的版本（模拟 Element 后台设的 5% 版税）
    function test_contractMakerSellWithRoyalty() public {
        uint256 tokenId = 4;
        uint256 price = 0.3 ether;
        _giveNftTo(address(vault), tokenId);
        vault.setApprovalForAll(address(NFT), address(EX));

        NFTSellOrder memory o = _order(tokenId, price);
        o.fees = new Fee[](1);
        o.fees[0] = Fee({recipient: VAULT_ROYALTY, amount: price / 10, feeData: ""});
        bytes32 h = EX.getERC721SellOrderHash(o);
        vault.approve(h);

        uint256 royaltyBefore = VAULT_ROYALTY.balance;
        uint256 vaultBefore = address(vault).balance;
        vm.prank(buyer);
        try EX.buyERC721Ex{value: price + price / 10}(o, Signature(3, 27, 0, 0), buyer, "") {
            console2.log(unicode"✅ 带版税成交成功");
            console2.log(unicode"   分红金库收到(wei):", VAULT_ROYALTY.balance - royaltyBefore);
            console2.log(unicode"   卖家(金库)收到(wei):", address(vault).balance - vaultBefore);
            console2.log(unicode"   NFT 归买家:", NFT.ownerOf(tokenId) == buyer);
        } catch Error(string memory e) {
            console2.log(unicode"❌ 失败:", e);
        } catch (bytes memory raw) {
            console2.log(unicode"❌ revert:"); console2.logBytes(raw);
        }
    }

    /// 对比：我们合约挂单成交 vs 真实用户成交，发出的事件是否一致
    /// 事件一致 → Element 的链下索引器无法区分 → 会照常计入成交量/地板价
    function test_eventsMatchRealSale() public {
        uint256 tokenId = 5;
        uint256 price = 0.3 ether;
        _giveNftTo(address(vault), tokenId);
        vault.setApprovalForAll(address(NFT), address(EX));
        NFTSellOrder memory o = _order(tokenId, price);
        o.fees = new Fee[](1);
        o.fees[0] = Fee({recipient: VAULT_ROYALTY, amount: price / 10, feeData: ""});
        vault.approve(EX.getERC721SellOrderHash(o));

        vm.recordLogs();
        vm.prank(buyer);
        EX.buyERC721Ex{value: price + price / 10}(o, Signature(3, 27, 0, 0), buyer, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log(unicode"我们的成交发出事件数:", logs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            console2.log(unicode"  来源:", logs[i].emitter);
            console2.logBytes32(logs[i].topics[0]);
        }
    }
}
