// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Aqua0BaseHook} from "../Aqua0BaseHook.sol";
import {SharedLiquidityPool} from "../SharedLiquidityPool.sol";

/// @title Aqua0Hook
/// @notice The default Aqua0 hook: plain shared liquidity, no custom logic.
///         Everything comes from Aqua0BaseHook's default _beforeSwap/_afterSwap.
///         Deploy at an address whose low 14 bits are BEFORE_SWAP | AFTER_SWAP (0x00C0).
contract Aqua0Hook is Aqua0BaseHook {
    constructor(IPoolManager _poolManager, SharedLiquidityPool _sharedPool) Aqua0BaseHook(_poolManager, _sharedPool) {}

    function hookName() public pure override returns (string memory) {
        return "Aqua0Hook (default shared liquidity)";
    }
}
