// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SharedLiquidityPool} from "../SharedLiquidityPool.sol";

/// @title Aqua0QuoteHelper
/// @notice Simulates a swap (hooks and Aqua0 virtual liquidity included) and reverts with the result.
///         Call `quote` with eth_call / staticCall and decode the `Quote` error.
contract Aqua0QuoteHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;
    SharedLiquidityPool public immutable sharedPool;

    /// @param amount0 Swapper's currency0 delta (negative = pays)
    /// @param amount1 Swapper's currency1 delta (positive = receives)
    /// @param slpDelta0 SLP holdings change in currency0
    /// @param slpDelta1 SLP holdings change in currency1
    error Quote(int256 amount0, int256 amount1, int256 slpDelta0, int256 slpDelta1);
    error NotPoolManager();

    constructor(SharedLiquidityPool _sharedPool) {
        sharedPool = _sharedPool;
        poolManager = _sharedPool.poolManager();
    }

    /// @param amountSpecified Negative = exact input, positive = exact output (v4 convention)
    function quote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) external {
        poolManager.unlock(abi.encode(key, zeroForOne, amountSpecified));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified) = abi.decode(data, (PoolKey, bool, int256));

        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        uint256 h0 = sharedPool.totalHoldings(t0);
        uint256 h1 = sharedPool.totalHoldings(t1);

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        revert Quote(
            delta.amount0(),
            delta.amount1(),
            int256(sharedPool.totalHoldings(t0)) - int256(h0),
            int256(sharedPool.totalHoldings(t1)) - int256(h1)
        );
    }
}
