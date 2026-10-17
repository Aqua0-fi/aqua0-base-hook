// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FaucetToken
/// @notice Testnet-only ERC20. Anyone can mint `faucetAmount` to themselves (or anyone) per call.
///         The creator can mint any amount, e.g. to seed liquidity. Worthless by design.
contract FaucetToken is ERC20 {
    uint8 private immutable _decimals;

    /// @notice Amount minted per faucet call
    uint256 public immutable faucetAmount;

    /// @notice Account that created the token through the factory
    address public immutable creator;

    error OnlyCreator();

    event FaucetUsed(address indexed to, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 faucetAmount_,
        address creator_,
        uint256 initialMint
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        faucetAmount = faucetAmount_;
        creator = creator_;
        if (initialMint > 0) _mint(creator_, initialMint);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `faucetAmount` to yourself
    function faucet() external {
        _mint(msg.sender, faucetAmount);
        emit FaucetUsed(msg.sender, faucetAmount);
    }

    /// @notice Mint `faucetAmount` to `to`
    function faucetTo(address to) external {
        _mint(to, faucetAmount);
        emit FaucetUsed(to, faucetAmount);
    }

    /// @notice Creator-only arbitrary mint
    function mint(address to, uint256 amount) external {
        if (msg.sender != creator) revert OnlyCreator();
        _mint(to, amount);
    }
}
