// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ICreatorToken, ITransferValidator} from "./interfaces/IExternal.sol";

/// @title 牛来 NFT (NIULAI) — BEP-721
/// @notice 999 枚，用 $牛来 代币铸造（默认 1000 枚/NFT）。10% 版税（ERC-2981）打到金库 NiuLaiVault，金库每小时买入 $牛来 并自动分发给持有者。
///         铸造收入按 treasury / vault（直接进入下一轮分红）/ burn 三路比例分账。
///         tokenId 从 1 连续到 999、不可销毁——金库靠这个顺序遍历持有人。
///         可选 ERC721-C 转账验证器（setTransferValidator），让 OpenSea 等市场在链上强制执行版税。
contract NiuLai is ERC721, ERC2981, Ownable2Step, ReentrancyGuard, ICreatorToken {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 999;
    uint96 public constant MAX_ROYALTY_BPS = 1000; // 10%

    // ---- 发售（用 $牛来 支付）----
    IERC20 public immutable payToken;            // $牛来
    uint256 public price = 1000 ether;           // 公售单价：1000 枚 $牛来（18 位）
    uint256 public allowlistPrice = 800 ether;   // 白名单单价
    uint32 public maxPerWallet = 5;
    uint32 public maxPerTx = 5;
    uint32 public reserveRemaining = 30;         // 团队/营销预留（从 999 里出）
    bool public publicSaleActive;
    bool public allowlistSaleActive;
    bytes32 public merkleRoot;
    mapping(address => uint32) public minted;    // 每钱包已铸（公售+白名单）
    uint256 private _nextId = 1;

    // ---- 元数据（实时 reveal：默认 revealed = true，tokenURI 直接指向 baseURI）----
    string private _baseTokenURI;
    string public unrevealedURI;
    string private _contractURI;
    bool public revealed = true;

    // ---- 资金 ----
    address public treasury;           // 铸造收入接收方
    address public vault;              // 金库：版税接收 + 铸造收入分成
    uint16 public treasuryBps = 10_000; // 铸造收入 → 国库
    uint16 public vaultBps;            // 铸造收入 → 金库（并入下一轮分红）
    uint16 public burnBps;             // 铸造收入 → 销毁（0xdead）
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    // ---- ERC721-C ----
    address private _transferValidator;

    event Minted(address indexed to, uint256 firstId, uint256 qty, uint256 paid);
    event SaleConfigUpdated(uint256 price, uint256 allowlistPrice, uint32 maxPerWallet, uint32 maxPerTx);
    event SaleStateUpdated(bool publicSale, bool allowlistSale);
    event Revealed(string baseURI);
    event Withdrawn(address indexed to, uint256 amount);
    event MintSplitUpdated(uint16 treasuryBps, uint16 vaultBps, uint16 burnBps);

    error SoldOut();
    error SaleClosed();
    error BadQuantity();
    error WalletLimit();
    error NotAllowlisted();
    error TransferFailed();
    error ZeroAddress();
    error RoyaltyTooHigh();

    constructor(address initialOwner, address payToken_, address treasury_, string memory baseURI_)
        ERC721(unicode"牛来 NFT", "NIULAI")
        Ownable(initialOwner)
    {
        if (treasury_ == address(0) || payToken_ == address(0)) revert ZeroAddress();
        payToken = IERC20(payToken_);
        treasury = treasury_;
        _baseTokenURI = baseURI_;
    }

    // ============ 铸造 ============

    /// @notice 公售：需先 payToken.approve(本合约, price*qty)
    function mint(uint32 qty) external nonReentrant {
        if (!publicSaleActive) revert SaleClosed();
        _mintMany(msg.sender, qty, price);
    }

    function allowlistMint(uint32 qty, bytes32[] calldata proof) external nonReentrant {
        if (!allowlistSaleActive) revert SaleClosed();
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert NotAllowlisted();
        _mintMany(msg.sender, qty, allowlistPrice);
    }

    /// @notice 团队预留铸造（不收费，不占钱包上限）
    function reserveMint(address to, uint32 qty) external onlyOwner {
        if (qty == 0 || qty > reserveRemaining) revert BadQuantity();
        if (_nextId + qty - 1 > MAX_SUPPLY) revert SoldOut();
        reserveRemaining -= qty;
        uint256 first = _nextId;
        for (uint256 i = 0; i < qty; i++) _safeMint(to, _nextId++);
        emit Minted(to, first, qty, 0);
    }

    function _mintMany(address to, uint32 qty, uint256 unitPrice) internal {
        if (qty == 0 || qty > maxPerTx) revert BadQuantity();
        if (minted[to] + qty > maxPerWallet) revert WalletLimit();
        // 公售/白名单不能吃掉团队预留
        if (_nextId + qty - 1 > MAX_SUPPLY - reserveRemaining) revert SoldOut();
        uint256 cost = unitPrice * qty;
        minted[to] += qty;
        // 先收款、再铸造（_safeMint 有外部回调，状态已先更新且有 nonReentrant）
        if (cost > 0) _collect(to, cost);
        uint256 first = _nextId;
        for (uint256 i = 0; i < qty; i++) _safeMint(to, _nextId++);
        emit Minted(to, first, qty, cost);
    }

    /// @dev 铸造收入三路分账：国库 / 金库（自动并入下一轮分红）/ 销毁
    function _collect(address from, uint256 cost) internal {
        uint256 toVault = (cost * vaultBps) / 10_000;
        uint256 toBurn = (cost * burnBps) / 10_000;
        uint256 toTreasury = cost - toVault - toBurn;
        if (toVault > 0) {
            if (vault == address(0)) revert ZeroAddress();
            payToken.safeTransferFrom(from, vault, toVault);
        }
        if (toBurn > 0) payToken.safeTransferFrom(from, BURN, toBurn);
        if (toTreasury > 0) payToken.safeTransferFrom(from, treasury, toTreasury);
    }

    function totalSupply() public view returns (uint256) {
        return _nextId - 1;
    }

    // ============ 元数据 ============

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (!revealed) return unrevealedURI;
        return string.concat(_baseTokenURI, tokenId.toString(), ".json");
    }

    /// @notice OpenSea 读取的合集级元数据（名称/描述/头图/版税）
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    // ============ ERC721-C ============

    function getTransferValidator() external view returns (address) {
        return _transferValidator;
    }

    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        return (ITransferValidator.validateTransfer.selector, true);
    }

    function setTransferValidator(address validator) external onlyOwner {
        emit TransferValidatorUpdated(_transferValidator, validator);
        _transferValidator = validator;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        // 只校验二级转账（铸造不校验）
        if (from != address(0) && to != address(0) && _transferValidator != address(0)) {
            ITransferValidator(_transferValidator).validateTransfer(_msgSender(), from, to, tokenId);
        }
        return super._update(to, tokenId, auth);
    }

    // ============ 管理 ============

    function setSaleConfig(uint256 price_, uint256 allowlistPrice_, uint32 maxPerWallet_, uint32 maxPerTx_) external onlyOwner {
        price = price_;
        allowlistPrice = allowlistPrice_;
        maxPerWallet = maxPerWallet_;
        maxPerTx = maxPerTx_;
        emit SaleConfigUpdated(price_, allowlistPrice_, maxPerWallet_, maxPerTx_);
    }

    function setSaleState(bool publicSale, bool allowlistSale) external onlyOwner {
        publicSaleActive = publicSale;
        allowlistSaleActive = allowlistSale;
        emit SaleStateUpdated(publicSale, allowlistSale);
    }

    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
    }

    function setReserve(uint32 remaining) external onlyOwner {
        if (_nextId - 1 + remaining > MAX_SUPPLY) revert BadQuantity();
        reserveRemaining = remaining;
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
    }

    function setUnrevealedURI(string calldata uri) external onlyOwner {
        unrevealedURI = uri;
    }

    function setContractURI(string calldata uri) external onlyOwner {
        _contractURI = uri;
    }

    function reveal(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        revealed = true;
        emit Revealed(baseURI_);
    }

    /// @notice 设置版税接收方与比例（≤10%）。上线时 receiver = 金库。
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        _setDefaultRoyalty(receiver, bps);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
    }

    function setVault(address vault_) external onlyOwner {
        vault = vault_;
    }

    /// @notice 铸造收入分账比例（万分比，三者之和必须 = 10000）
    function setMintSplit(uint16 treasuryBps_, uint16 vaultBps_, uint16 burnBps_) external onlyOwner {
        if (uint256(treasuryBps_) + vaultBps_ + burnBps_ != 10_000) revert BadQuantity();
        treasuryBps = treasuryBps_;
        vaultBps = vaultBps_;
        burnBps = burnBps_;
        emit MintSplitUpdated(treasuryBps_, vaultBps_, burnBps_);
    }

    function setRevealed(bool revealed_) external onlyOwner {
        revealed = revealed_;
    }

    /// @notice 误转进合约的 BNB
    function withdrawBNB() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        (bool ok,) = treasury.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(treasury, bal);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    // ============ ERC165 ============

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return interfaceId == type(ICreatorToken).interfaceId || super.supportsInterface(interfaceId);
    }
}
