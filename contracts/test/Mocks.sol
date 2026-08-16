// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPancakeV3SwapRouter} from "../src/interfaces/IExternal.sol";

contract MockToken is ERC20 {
    constructor() ERC20(unicode"牛来", unicode"牛来") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

/// @dev 固定汇率的假 router：1 BNB → rate 个 token；尊重 amountOutMinimum
contract MockRouter is IPancakeV3SwapRouter {
    MockToken public token;
    uint256 public rate; // token per 1 ether of BNB (18 decimals)

    constructor(MockToken token_, uint256 rate_) {
        token = token_;
        rate = rate_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        if (msg.value == 0) {
            address tokenIn = address(bytes20(p.path[0:20]));
            ERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        } else {
            require(msg.value == p.amountIn, "value");
        }
        amountOut = (p.amountIn * rate) / 1 ether;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        token.mint(p.recipient, amountOut);
    }

    function refundETH() external payable {}
}

/// @dev 假的 ERC721-C 验证器：拉黑某个操作者
contract MockValidator {
    address public blockedOperator;

    constructor(address blocked) {
        blockedOperator = blocked;
    }

    function validateTransfer(address caller, address, address, uint256) external view {
        require(caller != blockedOperator, "operator blocked");
    }
}

/// @dev 收不了 BNB 的合约（用于测试 keeper 报酬失败场景）
contract Rejector {
    receive() external payable {
        revert("no");
    }
}
