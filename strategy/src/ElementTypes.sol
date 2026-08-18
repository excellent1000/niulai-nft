// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct Fee { address recipient; uint256 amount; bytes feeData; }
struct Property { address propertyValidator; bytes propertyData; }

struct NFTSellOrder {
    address maker; address taker; uint256 expiry; uint256 nonce;
    address erc20Token; uint256 erc20TokenAmount; Fee[] fees;
    address nft; uint256 nftId;
}

struct NFTBuyOrder {
    address maker; address taker; uint256 expiry; uint256 nonce;
    address erc20Token; uint256 erc20TokenAmount; Fee[] fees;
    address nft; uint256 nftId; Property[] nftProperties;
}

struct ElementSignature { uint8 signatureType; uint8 v; bytes32 r; bytes32 s; }

interface IElementEx {
    function preSignERC721BuyOrder(NFTBuyOrder calldata order) external;
    function cancelERC721Order(uint256 orderNonce) external;
    function getERC721BuyOrderHash(NFTBuyOrder calldata order) external view returns (bytes32);
    function getERC721SellOrderHash(NFTSellOrder calldata order) external view returns (bytes32);
    function sellERC721(NFTBuyOrder calldata order, ElementSignature calldata sig, uint256 tokenId, bool unwrapNative, bytes calldata cb) external;
    function buyERC721Ex(NFTSellOrder calldata order, ElementSignature calldata sig, address taker, bytes calldata extraData)
        external payable;
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
