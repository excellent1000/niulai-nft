// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev PancakeSwap V3 SwapRouter（BSC: 0x1b81D678ffb9C0263b24A97847620C99d213eB14）。
///      exactInput 支持多跳 path = token0 ‖ fee(uint24) ‖ token1 ‖ fee ‖ token2 …；以 WBNB 开头时可直接附带 msg.value。
interface IPancakeV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function refundETH() external payable;
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

/// @dev ERC721-C（Limit Break creator-token-standards v3+）接口：OpenSea 等市场据此识别并执行链上版税策略。
///      验证器地址需按 BSC 上的官方部署填写；不设置时合约就是普通 ERC721 + ERC-2981。
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
    function setTransferValidator(address validator) external;
}

interface ITransferValidator {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}

/// @dev NFT 合约向金库暴露的分红入口
interface INiuLaiRewards {
    function notifyReward(uint256 amount) external;
    function rewardToken() external view returns (address);
}
