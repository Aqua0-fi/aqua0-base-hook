// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockYieldVault
/// @notice Stand-in for Aave / an Ondo-style yield token: a plain ERC4626 vault.
///         Yield is simulated by donating underlying with `simulateYield`, which raises the share price.
contract MockYieldVault is ERC4626 {
    using SafeERC20 for IERC20;

    event YieldSimulated(uint256 amount);

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}

    function simulateYield(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit YieldSimulated(amount);
    }
}
