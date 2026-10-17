// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SharedLiquidityPool} from "../SharedLiquidityPool.sol";

/// @title Aqua0Lens
/// @notice Read-only helpers for frontends and scripts. Holds no funds, has no admin.
contract Aqua0Lens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SharedLiquidityPool public immutable sharedPool;
    IPoolManager public immutable poolManager;

    struct PoolState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        uint128 liquidity;
    }

    struct PositionView {
        bytes32 positionId;
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool active;
        uint256 amount0Now; // token0 this liquidity represents at the current price
        uint256 amount1Now; // token1 this liquidity represents at the current price
    }

    constructor(SharedLiquidityPool _sharedPool) {
        sharedPool = _sharedPool;
        poolManager = _sharedPool.poolManager();
    }

    function getPoolState(PoolId poolId) public view returns (PoolState memory s) {
        (s.sqrtPriceX96, s.tick, s.protocolFee, s.lpFee) = poolManager.getSlot0(poolId);
        s.liquidity = poolManager.getLiquidity(poolId);
    }

    /// @notice Liquidity you get for up to (amount0, amount1) in [tickLower, tickUpper] at the current price,
    ///         plus the amounts that liquidity actually represents. Feed the result to `addPosition`.
    function liquidityForAmounts(PoolId poolId, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        view
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        (used0, used1) = amountsForLiquidity(poolId, tickLower, tickUpper, liquidity);
    }

    /// @notice Token amounts `liquidity` represents in a range at the current price (rounded up = what JIT costs)
    function amountsForLiquidity(PoolId poolId, int24 tickLower, int24 tickUpper, uint128 liquidity)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tick < tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true);
        } else if (tick < tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
        }
    }

    /// @notice All positions a user ever opened in the SLP, with current token value
    function getUserPositions(address user) external view returns (PositionView[] memory views) {
        bytes32[] memory ids = sharedPool.getUserPositionIds(user);
        views = new PositionView[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            (PoolId poolId, int24 tl, int24 tu, uint128 liq,,, bool active) = sharedPool.userPositions(user, ids[i]);
            views[i] = PositionView({
                positionId: ids[i],
                poolId: poolId,
                tickLower: tl,
                tickUpper: tu,
                liquidity: liq,
                active: active,
                amount0Now: 0,
                amount1Now: 0
            });
            if (active && liq > 0) {
                (views[i].amount0Now, views[i].amount1Now) = amountsForLiquidity(poolId, tl, tu, liq);
            }
        }
    }

    /// @notice Free balances and unclaimed fees for a list of tokens
    function getUserBalances(address user, address[] calldata tokens)
        external
        view
        returns (uint256[] memory free, uint256[] memory fees)
    {
        free = new uint256[](tokens.length);
        fees = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            free[i] = sharedPool.freeBalance(user, tokens[i]);
            fees[i] = sharedPool.earnedFees(user, tokens[i]);
        }
    }

    /// @notice SLP solvency snapshot per token
    function getPoolHoldings(address[] calldata tokens)
        external
        view
        returns (uint256[] memory liquid, uint256[] memory claims, uint256[] memory liabilities)
    {
        liquid = new uint256[](tokens.length);
        claims = new uint256[](tokens.length);
        liabilities = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            liquid[i] = sharedPool.liquidBalance(tokens[i]);
            claims[i] = sharedPool.claimBalance(tokens[i]);
            liabilities[i] = sharedPool.totalLiabilities(tokens[i]);
        }
    }
}
