// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title NLSTR —— NiuLaiStrategy 代币
/// @notice 标准 ERC20：固定总量、无铸造权限、**零转账税**。
///         10% 的费用在 Uniswap v4 池子的 swap 层收取（见 NLSTRHook），
///         因此本代币在任何钱包/聚合器/扫描器眼里都是干净的普通代币。
contract NLSTR is ERC20, ERC20Burnable {
    constructor(address recipient, uint256 supply) ERC20("NiuLaiStrategy", "NLSTR") {
        _mint(recipient, supply);
    }
}
