// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Aqua0BaseHook} from "../Aqua0BaseHook.sol";
import {SharedLiquidityPool} from "../SharedLiquidityPool.sol";

/// @title HookTemplate
/// @notice Copy this file to start your own Aqua0 hook.
///         You write a normal Uniswap v4 hook (OpenZeppelin BaseHook style: override the `_` functions),
///         except you extend Aqua0BaseHook and keep three calls in place.
contract HookTemplate is Aqua0BaseHook {
    // your state goes here
    uint256 public swaps;

    constructor(IPoolManager _poolManager, SharedLiquidityPool _sharedPool) Aqua0BaseHook(_poolManager, _sharedPool) {}

    /// @dev Shown in the residency explorer
    function hookName() public pure override returns (string memory) {
        return "HookTemplate";
    }

    /// @dev Turn on any extra callbacks you need. beforeSwap and afterSwap must stay on.
    ///      Remember: the hook address must have exactly these flag bits (script/DeployMyHook.s.sol mines it).
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true; // required by Aqua0
        permissions.afterSwap = true; // required by Aqua0
        // permissions.afterInitialize = true;   // e.g. if you want to set up per-pool state
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // (optional) checks that may reject the swap, before borrowing liquidity

        _addVirtualLiquidity(key); // <-- Aqua0: shared liquidity in

        // your logic: dynamic fees, KYC, oracles, pulling funds from a yield vault, ...
        swaps++;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        (bool hasJIT,) = _removeVirtualLiquidity(key); // <-- Aqua0: shared liquidity out
        if (hasJIT) _settleVirtualLiquidityDeltas(key); // <-- Aqua0: settle with the SLP

        // your logic: rebalance, re-deposit into a vault, emit analytics, ...

        return (IHooks.afterSwap.selector, 0);
    }
}
