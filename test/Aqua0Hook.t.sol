// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Aqua0TestBase} from "./utils/Aqua0TestBase.sol";

/// @notice End-to-end swaps through the default Aqua0Hook backed only by SLP liquidity
contract Aqua0HookTest is Aqua0TestBase {
    function setUp() public {
        _setUpCore();
        _deposit(lpA, token0, 1000e18);
        _deposit(lpA, token1, 1000e18);
        _addPosition(lpA, key, -600, 600, 100e18, 100e18);
    }

    function test_swapOnFreshPool_zeroForOne_exactIn() public {
        assertEq(MockERC20(token0).balanceOf(address(manager)), 0, "precondition: no PM reserves");
        uint256 h0 = _holdings(token0);
        uint256 h1 = _holdings(token1);

        BalanceDelta d = swap(key, true, -1e18, ZERO_BYTES);
        console.log("swapper paid token0", uint256(int256(-d.amount0())));
        console.log("swapper got token1 ", uint256(int256(d.amount1())));

        assertEq(d.amount0(), -1e18);
        assertGt(d.amount1(), 0.98e18);
        // the SLP took the other side of the whole swap (it is the only liquidity)
        assertApproxEqAbs(_holdings(token0) - h0, 1e18, 4, "slp token0 in");
        assertApproxEqAbs(h1 - _holdings(token1), uint256(int256(d.amount1())), 4, "slp token1 out");
        // LP books match
        assertApproxEqAbs(_total(lpA, token0), 1000e18 + 1e18, 8, "lp token0");
        assertApproxEqAbs(_total(lpA, token1), 1000e18 - uint256(int256(d.amount1())), 8, "lp token1");
        // 0.3% of the input is booked as fees
        assertApproxEqAbs(slp.earnedFees(lpA, token0), 0.003e18, 2, "fees");
        _assertSolvent(token0);
        _assertSolvent(token1);
        _assertHookClean(address(hook), key);
        // gains arrived as claims because the PM had no reserves mid-swap
        assertGt(slp.claimBalance(token0), 0, "claims held");
    }

    function test_swap_oneForZero_and_exactOut() public {
        BalanceDelta d1 = swap(key, false, -2e18, ZERO_BYTES); // exact in, token1 -> token0
        assertGt(d1.amount0(), 0);
        BalanceDelta d2 = swap(key, true, 5e17, ZERO_BYTES); // exact out 0.5 token1
        assertEq(d2.amount1(), 5e17);
        _assertSolvent(token0);
        _assertSolvent(token1);
        _assertHookClean(address(hook), key);
    }

    function test_roundTrip_lpEndsWithFees() public {
        for (uint256 i = 0; i < 5; i++) {
            swap(key, true, -3e18, ZERO_BYTES);
            swap(key, false, -3e18, ZERO_BYTES);
        }
        assertGt(slp.earnedFees(lpA, token0), 0);
        assertGt(slp.earnedFees(lpA, token1), 0);
        _assertSolvent(token0);
        _assertSolvent(token1);
    }

    function test_withdrawEverything_redeemsClaims() public {
        swap(key, true, -10e18, ZERO_BYTES);
        swap(key, false, -4e18, ZERO_BYTES);

        uint256 free0 = slp.freeBalance(lpA, token0);
        uint256 free1 = slp.freeBalance(lpA, token1);
        vm.startPrank(lpA);
        slp.removePosition(key, -600, 600, lpA);
        slp.withdraw(token0, free0, lpA, lpA);
        slp.withdraw(token1, free1, lpA, lpA);
        slp.claimFees(token0, lpA, lpA);
        slp.claimFees(token1, lpA, lpA);
        vm.stopPrank();

        assertGt(MockERC20(token0).balanceOf(lpA), 1000e18, "lp got its token0 + gains");
        assertEq(slp.totalLiabilities(token0), 0);
        assertEq(slp.totalLiabilities(token1), 0);
        // only rounding dust can remain
        assertLe(slp.totalHoldings(token0), 20);
        assertLe(slp.totalHoldings(token1), 20);
    }

    function test_twoLPs_shareProRata() public {
        _deposit(lpB, token0, 1000e18);
        _deposit(lpB, token1, 1000e18);
        _addPosition(lpB, key, -600, 600, 300e18, 300e18); // 3x lpA's liquidity

        uint256 a1 = _total(lpA, token1);
        uint256 b1 = _total(lpB, token1);
        uint256 a0 = _total(lpA, token0);
        uint256 b0 = _total(lpB, token0);
        swap(key, true, -4e18, ZERO_BYTES);
        uint256 lossA = a1 - _total(lpA, token1);
        uint256 lossB = b1 - _total(lpB, token1);
        uint256 gainA = _total(lpA, token0) - a0;
        uint256 gainB = _total(lpB, token0) - b0;
        assertApproxEqRel(lossB, lossA * 3, 1e14);
        assertApproxEqRel(gainB, gainA * 3, 1e14);
        _assertSolvent(token0);
        _assertSolvent(token1);
    }

    function test_underfundedLP_isScaledDown_neverOverdrawn() public {
        // lpB claims liquidity worth 500/500 but only deposited 10/10
        _deposit(lpB, token0, 10e18);
        _deposit(lpB, token1, 10e18);
        uint128 liq = _liquidityFor(key, -600, 600, 500e18, 500e18);
        vm.prank(lpB);
        slp.addPosition(key, -600, 600, liq, 10e18, 10e18, lpB);

        swap(key, true, -50e18, ZERO_BYTES);
        swap(key, true, -50e18, ZERO_BYTES);
        // lpB can lose at most what it deposited, and the pool stays solvent
        assertLe(10e18 - slp.freeBalance(lpB, token1), 10e18);
        _assertSolvent(token0);
        _assertSolvent(token1);
        _assertHookClean(address(hook), key);
    }

    function test_unbackedPosition_cannotDrainOthers() public {
        // The attack that drained the cohort-8 pool: declare 0/0 reserves with no deposit.
        uint128 liq = _liquidityFor(key, -60, 60, 500e18, 500e18);
        vm.prank(attacker);
        slp.addPosition(key, -60, 60, liq, 0, 0, attacker);

        swap(key, true, -50e18, ZERO_BYTES);
        assertEq(_total(attacker, token0), 0, "attacker credited nothing");
        assertEq(_total(attacker, token1), 0);
        _assertSolvent(token0);
        _assertSolvent(token1);
    }

    function test_rangeScaledToZero_doesNotBrickSwaps() public {
        // lpB opens a position then withdraws everything; its range must be skipped, not revert.
        _deposit(lpB, token0, 5e18);
        _deposit(lpB, token1, 5e18);
        _addPosition(lpB, key, -1200, 1200, 5e18, 5e18);
        vm.startPrank(lpB);
        slp.withdraw(token0, 5e18, lpB, lpB);
        slp.withdraw(token1, 5e18, lpB, lpB);
        vm.stopPrank();

        swap(key, true, -1e18, ZERO_BYTES);
        _assertSolvent(token0);
    }

    function test_nativeEthPool() public {
        PoolKey memory ethKey;
        (ethKey,) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        _deposit(lpB, address(0), 100e18);
        _deposit(lpB, token1, 100e18);
        _addPosition(lpB, ethKey, -600, 600, 50e18, 50e18);

        swapNativeInput(ethKey, true, -1e18, ZERO_BYTES, 1e18); // ETH in
        swap(ethKey, false, -2e18, ZERO_BYTES); // ETH out
        _assertSolvent(address(0));
        _assertSolvent(token1);
        _assertHookClean(address(hook), ethKey);

        uint256 freeEth = slp.freeBalance(lpB, address(0));
        uint256 before = lpB.balance;
        vm.prank(lpB);
        slp.withdraw(address(0), freeEth, lpB, lpB);
        assertEq(lpB.balance - before, freeEth);
    }

    function test_noPositions_swapIsPlainV4() public {
        vm.prank(lpA);
        slp.removePosition(key, -600, 600, lpA);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 h0 = _holdings(token0);
        swap(key, true, -1e15, ZERO_BYTES);
        assertEq(_holdings(token0), h0, "SLP untouched");
    }

    function test_pause_skipsVirtualLiquidity_withdrawStillWorks() public {
        slp.setPaused(true);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 h0 = _holdings(token0);
        swap(key, true, -1e15, ZERO_BYTES);
        assertEq(_holdings(token0), h0);
        vm.prank(lpA);
        slp.withdraw(token0, 1e18, lpA, lpA);
    }
}
