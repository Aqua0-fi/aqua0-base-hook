// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Aqua0Constants
/// @notice Values shared by the SharedLiquidityPool and every Aqua0BaseHook.
library Aqua0Constants {
    /// @notice PoolManager position salt used for just-in-time (virtual) liquidity.
    /// @dev A dedicated salt keeps Aqua0's temporary position separate from any liquidity
    ///      your hook adds for itself (which normally uses salt 0).
    bytes32 internal constant JIT_SALT = keccak256("aqua0.jit.v1");
}
