// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IAqua0BaseHookMarker
/// @notice ERC165 marker that identifies a hook built on Aqua0BaseHook.
/// @dev The SharedLiquidityPool and the residency indexer use this to recognise Aqua0 hooks.
///      Answering `true` here gives a contract no special power over anyone's funds: the pool
///      only lets a hook touch positions in pools where that hook is `key.hooks`.
interface IAqua0BaseHookMarker is IERC165 {
    /// @notice Returns true if the contract is an Aqua0 base hook
    function isAqua0BaseHook() external pure returns (bool);
}
