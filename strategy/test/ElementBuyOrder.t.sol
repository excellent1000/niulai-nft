// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct Fee { address recipient; uint256 amount; bytes feeData; }
struct Property { address propertyValidator; bytes propertyData; }
struct NFTBuyOrder {
    address maker; address taker; uint256 expiry; uint256 nonce;
    address erc20Token; uint256 erc20TokenAmount; Fee[] fees;
    address nft; uint256 nftId; Property[] nftProperties;
}
struct Signature { uint8 signatureType; uint8 v; bytes32 r; bytes32 s; }

interface IElementEx {
    function preSignERC721BuyOrder(NFTBuyOrder calldata order) external;
    function sellERC721(NFTBuyOrder calldata order, Signature calldata sig, uint256 tokenId, bool unwrapNative, bytes calldata cb) external;
    function getERC721BuyOrderHash(NFTBuyOrder calldata order) external view returns (bytes32);
}
interface IWBNB is IERC20 { function deposit() external payable; }

/// 模拟金库：链上预签名挂买单
contract MockVault {
    function preSign(address ex, NFTBuyOrder calldata o) external { IElementEx(ex).preSignERC721BuyOrder(o); }
    function approveWbnb(address w, address ex) external { IERC20(w).approve(ex, type(uint256).max); }
    function wrap(address w) external payable { IWBNB(w).deposit{value: msg.value}(); }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return 0x150b7a02; }
    receive() external payable {}
}

contract ElementBuyOrder is Test {
    IElementEx constant EX = IElementEx(0xb3e3DfCb2d9f3DdE16d78B9e6EB3538Eb32B5ae1);
    IERC721 constant NFT = IERC721(0x5fd0d8FeCF408f61080cEa470249026d3e02fB3D);
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    MockVault vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        vault = new MockVault();
        vm.deal(address(this), 100 ether);
        vault.wrap{value: 5 ether}(WBNB);
        vault.approveWbnb(WBNB, address(EX));
    }

    function test_contractCanPlaceOnchainBuyOrder() public {
        uint256 price = 0.25 ether;
        NFTBuyOrder memory o;
        o.maker = address(vault);
        o.taker = address(0);
        o.expiry = block.timestamp + 7 days;
        o.nonce = 999001;
        o.erc20Token = WBNB;              // 买单必须用 WBNB
        o.erc20TokenAmount = price;
        o.fees = new Fee[](0);
        o.nft = address(NFT);
        o.nftId = 7;
        o.nftProperties = new Property[](0);

        // 链上预签名（合约自己发起，不需要私钥签名，也不需要任何 API）
        vault.preSign(address(EX), o);
        console2.log(unicode"✅ 合约已链上挂出买单，价格(wei):", price);

        // 一个真实持有者来吃这个买单
        address holder = NFT.ownerOf(7);
        uint256 holderBefore = holder.balance;
        vm.startPrank(holder);
        NFT.setApprovalForAll(address(EX), true);
        try EX.sellERC721(o, Signature(1, 0, 0, 0), 7, true, "") {   // signatureType 1 = PRESIGNED
            console2.log(unicode"✅ 持有者成功卖给合约");
            console2.log(unicode"   NFT 现属金库:", NFT.ownerOf(7) == address(vault));
            console2.log(unicode"   卖家收到 BNB(wei):", holder.balance - holderBefore);
            console2.log(unicode"   金库剩余 WBNB(wei):", IERC20(WBNB).balanceOf(address(vault)));
        } catch Error(string memory e) {
            console2.log(unicode"❌ 失败:", e);
        } catch (bytes memory raw) {
            console2.log(unicode"❌ revert:"); console2.logBytes(raw);
        }
        vm.stopPrank();
    }
}
