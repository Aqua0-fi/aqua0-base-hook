// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Aqua0BaseHook} from "../Aqua0BaseHook.sol";
import {SharedLiquidityPool} from "../SharedLiquidityPool.sol";

/// @title SwapCounterHook (example)
/// @notice A deliberately silly hook that shows custom logic living next to Aqua0 shared liquidity:
///           - rejects swaps bigger than `maxSwapSize`
///           - counts swaps per pool
///           - "happy hour": every even-numbered swap pays 0.05% instead of 0.30%
///             (only when the pool was created with the dynamic-fee flag)
///           - emits a Vibe event after each swap
contract SwapCounterHook is Aqua0BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint24 public constant HAPPY_HOUR_FEE = 500; // 0.05%
    uint24 public constant FULL_PRICE_FEE = 3000; // 0.30%

    uint256 public immutable maxSwapSize;

    mapping(PoolId => uint256) public swapCount;

    event Vibe(PoolId indexed poolId, uint256 swapNumber, uint24 feeCharged, string mood);

    error SwapTooBig(uint256 size, uint256 max);

    constructor(IPoolManager _poolManager, SharedLiquidityPool _sharedPool, uint256 _maxSwapSize)
        Aqua0BaseHook(_poolManager, _sharedPool)
    {
        maxSwapSize = _maxSwapSize;
    }

    function hookName() public pure override returns (string memory) {
        return "SwapCounterHook (example: happy-hour fees)";
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // custom check first: no point borrowing liquidity for a swap we are about to reject
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (size > maxSwapSize) revert SwapTooBig(size, maxSwapSize);

        // 1. Aqua0: bring shared liquidity in
        _addVirtualLiquidity(key);

        // 2. your logic
        uint256 n = ++swapCount[key.toId()];
        uint24 feeOverride;
        if (key.fee.isDynamicFee()) {
            feeOverride = (n % 2 == 0 ? HAPPY_HOUR_FEE : FULL_PRICE_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // 1. Aqua0: take shared liquidity back out and settle with the SLP
        (bool hasJIT,) = _removeVirtualLiquidity(key);
        if (hasJIT) _settleVirtualLiquidityDeltas(key);

        // 2. your logic
        PoolId id = key.toId();
        uint256 n = swapCount[id];
        bool happy = n % 2 == 0;
        uint24 fee = key.fee.isDynamicFee() ? (happy ? HAPPY_HOUR_FEE : FULL_PRICE_FEE) : key.fee;
        emit Vibe(id, n, fee, happy ? "happy hour" : "full price");
        return (IHooks.afterSwap.selector, 0);
    }
}
