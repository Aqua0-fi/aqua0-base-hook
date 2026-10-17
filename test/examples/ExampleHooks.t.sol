// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapCounterHook} from "../../src/examples/SwapCounterHook.sol";
import {YieldParkingHook} from "../../src/examples/YieldParkingHook.sol";
import {MockYieldVault} from "../../src/examples/mocks/MockYieldVault.sol";
import {Aqua0TestBase} from "../utils/Aqua0TestBase.sol";

contract SwapCounterHookTest is Aqua0TestBase {
    SwapCounterHook counter;
    PoolKey ck;

    function setUp() public {
        _setUpCore();
        counter = SwapCounterHook(
            payable(_deployHook("SwapCounterHook.sol:SwapCounterHook", abi.encode(manager, slp, 20e18), AQUA0_FLAGS))
        );
        (ck,) = initPool(currency0, currency1, IHooks(address(counter)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        _deposit(lpA, token0, 1000e18);
        _deposit(lpA, token1, 1000e18);
        _addPosition(lpA, ck, -600, 600, 200e18, 200e18);
    }

    function test_customLogicRunsAlongsideSharedLiquidity() public {
        uint256 f0 = slp.earnedFees(lpA, token0);
        swap(ck, true, -1e18, ZERO_BYTES); // swap #1: full price
        uint256 fullPrice = slp.earnedFees(lpA, token0) - f0;
        f0 = slp.earnedFees(lpA, token0);
        swap(ck, true, -1e18, ZERO_BYTES); // swap #2: happy hour
        uint256 happyHour = slp.earnedFees(lpA, token0) - f0;

        assertEq(counter.swapCount(ck.toId()), 2);
        assertApproxEqAbs(fullPrice, 3e15, 2, "0.30%");
        assertApproxEqAbs(happyHour, 5e14, 2, "0.05%");
        _assertSolvent(token0);
        _assertSolvent(token1);
        _assertHookClean(address(counter), ck);
    }

    function test_rejectsBigSwaps() public {
        vm.expectRevert();
        swap(ck, true, -21e18, ZERO_BYTES);
    }
}

contract YieldParkingHookTest is Aqua0TestBase {
    YieldParkingHook yh;
    MockYieldVault v0;
    MockYieldVault v1;
    PoolKey yk;

    function setUp() public {
        _setUpCore();
        yh = YieldParkingHook(
            payable(_deployHook(
                    "YieldParkingHook.sol:YieldParkingHook", abi.encode(manager, slp, address(this)), AQUA0_FLAGS
                ))
        );
        v0 = new MockYieldVault(IERC20(token0), "Mock aToken0", "aT0");
        v1 = new MockYieldVault(IERC20(token1), "Mock aToken1", "aT1");
        yh.setVault(token0, IERC4626(address(v0)));
        yh.setVault(token1, IERC4626(address(v1)));
        (yk,) = initPool(currency0, currency1, IHooks(address(yh)), 3000, SQRT_PRICE_1_1);

        MockERC20(token0).approve(address(yh), type(uint256).max);
        MockERC20(token1).approve(address(yh), type(uint256).max);
        MockERC20(token0).approve(address(v0), type(uint256).max);
        yh.fund(token0, 500e18);
        yh.fund(token1, 500e18);
        yh.allocate(yk, -600, 600, _liquidityFor(yk, -600, 600, 200e18, 200e18));
    }

    function test_idleFundsSitInVault_untilSwap() public {
        assertEq(slp.freeBalance(address(yh), token0), 0, "nothing idle in SLP");
        assertEq(yh.parkedAssets(token0), 500e18, "all in vault");

        uint256 slpBefore = slp.totalHoldings(token1);
        BalanceDeltaView memory d = _swapView(true, -5e18);
        assertGt(d.out, 4.9e18, "swap served by parked liquidity");

        // after the swap, the token that left went straight back to the vault
        assertEq(slp.freeBalance(address(yh), token1), 0);
        assertApproxEqAbs(yh.parkedAssets(token1), 500e18 - d.out, 4);
        assertEq(slp.totalHoldings(token1), slpBefore, "SLP back to where it was for token1");
        // the input token: whatever was plain tokens is parked; this swap's gains sit in the SLP as claims
        assertGt(slp.freeBalance(address(yh), token0), 0);
        yh.sweep(token0);
        assertEq(slp.freeBalance(address(yh), token0), 0);
        assertApproxEqAbs(yh.parkedAssets(token0), 505e18 - slp.earnedFees(address(yh), token0), 4);
        _assertHookClean(address(yh), yk);
    }

    function test_yieldAccrues_andIsUsedOnNextSwap() public {
        uint256 before = yh.totalManaged(token0);
        v0.simulateYield(50e18);
        assertApproxEqAbs(yh.totalManaged(token0), before + 50e18, 1);
        swap(yk, false, -3e18, ZERO_BYTES);
        swap(yk, true, -3e18, ZERO_BYTES);
        _assertSolvent(token0);
        _assertSolvent(token1);
    }

    function test_otherLPsShareTheSamePool() public {
        _deposit(lpA, token0, 100e18);
        _deposit(lpA, token1, 100e18);
        _addPosition(lpA, yk, -600, 600, 100e18, 100e18);
        uint256 a1 = _total(lpA, token1);
        swap(yk, true, -6e18, ZERO_BYTES);
        assertLt(_total(lpA, token1), a1, "regular LP took part");
        assertGt(_total(lpA, token0), 100e18, "and earned the input token");
        _assertSolvent(token0);
        _assertSolvent(token1);
    }

    struct BalanceDeltaView {
        uint256 out;
    }

    function _swapView(bool zeroForOne, int256 amount) internal returns (BalanceDeltaView memory v) {
        int256 out = zeroForOne
            ? swap(yk, zeroForOne, amount, ZERO_BYTES).amount1()
            : swap(yk, zeroForOne, amount, ZERO_BYTES).amount0();
        v.out = uint256(out);
    }
}
