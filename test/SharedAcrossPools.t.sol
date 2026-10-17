// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapCounterHook} from "../src/examples/SwapCounterHook.sol";
import {YieldParkingHook} from "../src/examples/YieldParkingHook.sol";
import {MockYieldVault} from "../src/examples/mocks/MockYieldVault.sol";
import {Aqua0TestBase} from "./utils/Aqua0TestBase.sol";

/// @notice One LP deposit backing four pools that use three different hooks
contract SharedAcrossPoolsTest is Aqua0TestBase {
    SwapCounterHook counter;
    YieldParkingHook yieldHook;
    PoolKey counterKey;
    PoolKey yieldKey;
    PoolKey pairBKey;
    address token2;

    function setUp() public {
        _setUpCore();
        counter = SwapCounterHook(
            payable(_deployHook("SwapCounterHook.sol:SwapCounterHook", abi.encode(manager, slp, 100e18), AQUA0_FLAGS))
        );
        yieldHook = YieldParkingHook(
            payable(_deployHook(
                    "YieldParkingHook.sol:YieldParkingHook", abi.encode(manager, slp, address(this)), AQUA0_FLAGS
                ))
        );
        (counterKey,) =
            initPool(currency0, currency1, IHooks(address(counter)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        (yieldKey,) = initPool(currency0, currency1, IHooks(address(yieldHook)), 3000, SQRT_PRICE_1_1);

        // a second pair (token1 / token2) on the default hook
        MockERC20 t2 = new MockERC20("Token2", "T2", 18);
        t2.mint(address(this), 1e30);
        t2.approve(address(swapRouter), type(uint256).max);
        token2 = address(t2);
        (Currency c0, Currency c1) = token1 < token2
            ? (Currency.wrap(token1), Currency.wrap(token2))
            : (Currency.wrap(token2), Currency.wrap(token1));
        (pairBKey,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        // the yield hook parks its own treasury too
        MockYieldVault v0 = new MockYieldVault(IERC20(token0), "a0", "a0");
        MockYieldVault v1 = new MockYieldVault(IERC20(token1), "a1", "a1");
        yieldHook.setVault(token0, IERC4626(address(v0)));
        yieldHook.setVault(token1, IERC4626(address(v1)));
        MockERC20(token0).approve(address(yieldHook), type(uint256).max);
        MockERC20(token1).approve(address(yieldHook), type(uint256).max);
        yieldHook.fund(token0, 100e18);
        yieldHook.fund(token1, 100e18);
        yieldHook.allocate(yieldKey, -600, 600, _liquidityFor(yieldKey, -600, 600, 50e18, 50e18));
    }

    function test_oneDeposit_backsFourPools() public {
        // ONE deposit...
        _deposit(lpA, token0, 100e18);
        _deposit(lpA, token1, 100e18);
        _deposit(lpA, token2, 100e18);
        // ...allocated (virtually) to four pools. Sum of allocations > deposit: that is the point.
        _addPosition(lpA, key, -600, 600, 80e18, 80e18);
        _addPosition(lpA, counterKey, -600, 600, 80e18, 80e18);
        _addPosition(lpA, yieldKey, -600, 600, 80e18, 80e18);
        _addPosition(lpA, pairBKey, -600, 600, 80e18, 80e18);

        uint256 start0 = _total(lpA, token0);
        uint256 start1 = _total(lpA, token1);

        swap(key, true, -2e18, ZERO_BYTES);
        swap(counterKey, true, -2e18, ZERO_BYTES);
        swap(yieldKey, false, -2e18, ZERO_BYTES);
        swap(pairBKey, true, -2e18, ZERO_BYTES);

        console.log("lpA token0 change (+):", _total(lpA, token0) - start0);
        console.log("lpA fees token0:", slp.earnedFees(lpA, token0));
        console.log("lpA fees token1:", slp.earnedFees(lpA, token1));

        assertGt(slp.earnedFees(lpA, token0), 0, "earned in pool A/B");
        assertGt(slp.earnedFees(lpA, token1), 0, "earned in yield pool");
        assertGt(_total(lpA, token0), start0, "net token0 gained across pools");
        assertTrue(_total(lpA, token1) != start1);

        _assertSolvent(token0);
        _assertSolvent(token1);
        _assertSolvent(token2);
        _assertHookClean(address(hook), key);
        _assertHookClean(address(counter), counterKey);
        _assertHookClean(address(hook), pairBKey);
    }
}
