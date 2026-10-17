// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FaucetToken} from "./FaucetToken.sol";

/// @title TokenFactory
/// @notice Launch a testnet token with a built-in faucet in one transaction.
///         The creator receives 1,000,000 tokens; anyone can call `faucet()` on the token for more.
contract TokenFactory {
    uint256 public constant INITIAL_SUPPLY_UNITS = 1_000_000;
    uint256 public constant DEFAULT_FAUCET_UNITS = 10_000;

    address[] private _tokens;

    /// @notice token => created by this factory
    mapping(address => bool) public isFactoryToken;

    event TokenCreated(
        address indexed token, address indexed creator, string name, string symbol, uint8 decimals, uint256 faucetAmount
    );

    error InvalidName();
    error InvalidSymbol();
    error InvalidDecimals();

    /// @param name         Token name, 1-32 bytes
    /// @param symbol       Token symbol, 1-12 bytes
    /// @param decimals_    0-18
    /// @param faucetUnits  Whole tokens per faucet call (0 = 10,000)
    function createToken(string calldata name, string calldata symbol, uint8 decimals_, uint256 faucetUnits)
        external
        returns (address token)
    {
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 12) revert InvalidSymbol();
        if (decimals_ > 18) revert InvalidDecimals();
        if (faucetUnits == 0 || faucetUnits > 1e12) faucetUnits = DEFAULT_FAUCET_UNITS;

        uint256 unit = 10 ** decimals_;
        uint256 faucetAmount = faucetUnits * unit;
        token = address(new FaucetToken(name, symbol, decimals_, faucetAmount, msg.sender, INITIAL_SUPPLY_UNITS * unit));

        _tokens.push(token);
        isFactoryToken[token] = true;
        emit TokenCreated(token, msg.sender, name, symbol, decimals_, faucetAmount);
    }

    function allTokens() external view returns (address[] memory) {
        return _tokens;
    }

    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }
}
