// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice 批量发币：一笔交易发给上百个地址，省 gas 也省时间。无状态、无权限、无资金留存。
contract BatchSender {
    error LengthMismatch();
    error TransferFailed();

    /// @dev 调用前需先 approve 本合约
    function disperse(IERC20 token, address[] calldata to, uint256[] calldata amounts) external {
        if (to.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < to.length; i++) {
            if (!token.transferFrom(msg.sender, to[i], amounts[i])) revert TransferFailed();
        }
    }
}
