// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Aqua0BaseHook} from "../src/Aqua0BaseHook.sol";
import {SharedLiquidityPool} from "../src/SharedLiquidityPool.sol";
import {Aqua0TestBase} from "./utils/Aqua0TestBase.sol";

/// @dev Answers the ERC165 marker but is not the hook of any pool (the cohort-8 drain vector)
contract FakeMarker {
    SharedLiquidityPool immutable slp;

    constructor(SharedLiquidityPool _slp) {
        slp = _slp;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function stealFrom(address token, address victim, uint256 amount) external {
        slp.withdraw(token, amount, victim, msg.sender);
    }

    function hijackSession(PoolKey calldata key) external {
        slp.preSwap(key);
    }
}

/// @dev A real Aqua0 hook that tries to use the SLP outside of an actual swap
contract RogueHook is Aqua0BaseHook, IUnlockCallback {
    constructor(IPoolManager pm, SharedLiquidityPool slp) Aqua0BaseHook(pm, slp) {}

    function openWithoutMinting(PoolKey calldata key) external {
        sharedPool.preSwap(key);
        sharedPool.checkpoint(key);
    }

    function postWithoutSession(PoolKey calldata key) external {
        sharedPool.postSwap(key);
    }

    function fakeSwap(PoolKey calldata key) external {
        poolManager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        this.jitWithoutSwap(abi.decode(data, (PoolKey)));
        return "";
    }

    function jitWithoutSwap(PoolKey calldata key) external {
        require(msg.sender == address(this));
        _addVirtualLiquidity(key);
        (bool hasJIT,) = _removeVirtualLiquidity(key);
        if (hasJIT) _settleVirtualLiquidityDeltas(key);
    }
}

/// @dev Tries to pull an LP's balance out mid-swap (after the LP made it an operator)
contract GreedyHook is Aqua0BaseHook {
    address public immutable victim;

    constructor(IPoolManager pm, SharedLiquidityPool slp, address _victim) Aqua0BaseHook(pm, slp) {
        victim = _victim;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _addVirtualLiquidity(key);
        sharedPool.withdraw(Currency.unwrap(key.currency1), 1e18, victim, address(this));
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

contract SecurityTest is Aqua0TestBase {
    function setUp() public {
        _setUpCore();
        _deposit(lpA, token0, 1000e18);
        _deposit(lpA, token1, 1000e18);
        _addPosition(lpA, key, -600, 600, 100e18, 100e18);
    }

    function test_markerContract_cannotWithdrawForOthers() public {
        FakeMarker fake = new FakeMarker(slp);
        vm.prank(attacker);
        vm.expectRevert(SharedLiquidityPool.NotAuthorized.selector);
        fake.stealFrom(token1, lpA, 1000e18);
    }

    function test_markerContract_cannotOpenSessionForAnotherHooksPool() public {
        FakeMarker fake = new FakeMarker(slp);
        vm.expectRevert(SharedLiquidityPool.CallerNotPoolHook.selector);
        fake.hijackSession(key);
    }

    function test_nobodyElse_canManagePositionsOrBalances() public {
        vm.startPrank(attacker);
        vm.expectRevert(SharedLiquidityPool.NotAuthorized.selector);
        slp.withdraw(token0, 1, lpA, attacker);
        vm.expectRevert(SharedLiquidityPool.NotAuthorized.selector);
        slp.claimFees(token0, lpA, attacker);
        vm.expectRevert(SharedLiquidityPool.NotAuthorized.selector);
        slp.removePosition(key, -600, 600, lpA);
        vm.expectRevert(SharedLiquidityPool.NotAuthorized.selector);
        slp.addPosition(key, -60, 60, 1e18, 0, 0, lpA);
        vm.stopPrank();
    }

    function test_operator_canActForOwner() public {
        vm.prank(lpA);
        slp.setOperator(lpB, true);
        vm.prank(lpB);
        slp.withdraw(token0, 1e18, lpA, lpB);
        assertEq(slp.freeBalance(lpA, token0), 999e18);
    }

    function test_rogueHook_cannotCheckpointWithoutLiquidity() public {
        RogueHook rogue =
            RogueHook(payable(_deployHook("Security.t.sol:RogueHook", abi.encode(manager, slp), AQUA0_FLAGS)));
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(rogue)), 3000, SQRT_PRICE_1_1);
        _addPosition(lpA, rk, -600, 600, 100e18, 100e18);

        vm.expectRevert(SharedLiquidityPool.VirtualLiquidityMissing.selector);
        rogue.openWithoutMinting(rk);
        vm.expectRevert(SharedLiquidityPool.NoOpenSession.selector);
        rogue.postWithoutSession(rk);
    }

    function test_rogueHook_fakeSwapGainsNothing() public {
        RogueHook rogue =
            RogueHook(payable(_deployHook("Security.t.sol:RogueHook", abi.encode(manager, slp), AQUA0_FLAGS)));
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(rogue)), 3000, SQRT_PRICE_1_1);
        _addPosition(lpA, rk, -600, 600, 100e18, 100e18);

        uint256 a0 = _total(lpA, token0);
        uint256 a1 = _total(lpA, token1);
        for (uint256 i = 0; i < 3; i++) {
            rogue.fakeSwap(rk);
        }
        // Without price movement the SLP books only PoolManager rounding (a few wei), never real value.
        assertLe(a0 - _total(lpA, token0), 10);
        assertLe(a1 - _total(lpA, token1), 10);
        _assertSolvent(token0);
        _assertSolvent(token1);
    }

    function test_withdrawMidSwap_isBlocked() public {
        GreedyHook greedy =
            GreedyHook(payable(_deployHook("Security.t.sol:GreedyHook", abi.encode(manager, slp, lpA), AQUA0_FLAGS)));
        (PoolKey memory gk,) = initPool(currency0, currency1, IHooks(address(greedy)), 3000, SQRT_PRICE_1_1);
        _addPosition(lpA, gk, -600, 600, 100e18, 100e18);
        vm.prank(lpA);
        slp.setOperator(address(greedy), true);

        vm.expectRevert(); // SwapInProgress, wrapped by the PoolManager
        swap(gk, true, -1e18, ZERO_BYTES);
    }

    function test_addPosition_validation() public {
        vm.startPrank(lpA);
        vm.expectRevert(SharedLiquidityPool.InvalidTicks.selector);
        slp.addPosition(key, 10, 600, 1e18, 0, 0, lpA); // not a multiple of tickSpacing 60
        vm.expectRevert(SharedLiquidityPool.InvalidTicks.selector);
        slp.addPosition(key, 600, 600, 1e18, 0, 0, lpA);
        vm.expectRevert(SharedLiquidityPool.InvalidTicks.selector);
        slp.addPosition(key, -887280, 600, 1e18, 0, 0, lpA); // below min usable tick
        vm.expectRevert(SharedLiquidityPool.InsufficientFreeBalance.selector);
        slp.addPosition(key, -60, 60, 1e18, 2000e18, 0, lpA);
        vm.expectRevert(SharedLiquidityPool.PositionAlreadyExists.selector);
        slp.addPosition(key, -600, 600, 1e18, 0, 0, lpA);
        vm.stopPrank();

        // pool without an Aqua0 hook
        (PoolKey memory plain,) = initPool(currency0, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1);
        vm.prank(lpA);
        vm.expectRevert(SharedLiquidityPool.NotAqua0Hook.selector);
        slp.addPosition(plain, -60, 60, 1e18, 0, 0, lpA);

        // Aqua0 hook but pool never initialized
        PoolKey memory uninit = key;
        uninit.fee = 10_000;
        vm.prank(lpA);
        vm.expectRevert(SharedLiquidityPool.PoolNotInitialized.selector);
        slp.addPosition(uninit, -600, 600, 1e18, 0, 0, lpA);
    }

    function test_limits_boundSwapGas() public {
        slp.setLimits(2, 2);
        _deposit(lpB, token0, 10e18);
        _deposit(lpB, token1, 10e18);
        _addPosition(lpB, key, -1200, 1200, 1e18, 1e18);
        vm.prank(lpB);
        vm.expectRevert(SharedLiquidityPool.TooManyRanges.selector);
        slp.addPosition(key, -1800, 1800, 1e18, 0, 0, lpB);

        vm.prank(attacker);
        slp.addPosition(key, -1200, 1200, 1e18, 0, 0, attacker);
        _deposit(lpB, token0, 1);
        vm.prank(makeAddr("third"));
        vm.expectRevert(SharedLiquidityPool.TooManyUsersInRange.selector);
        slp.addPosition(key, -1200, 1200, 1e18, 0, 0, makeAddr("third"));

        // leaving frees the slot
        vm.prank(attacker);
        slp.removePosition(key, -1200, 1200, attacker);
        vm.prank(makeAddr("third"));
        slp.addPosition(key, -1200, 1200, 1e18, 0, 0, makeAddr("third"));
    }

    function test_onlyOwner_admin() public {
        vm.prank(attacker);
        vm.expectRevert();
        slp.setPaused(true);
        vm.prank(attacker);
        vm.expectRevert();
        slp.setLimits(1, 1);
    }

    function test_hookMustKeepSwapPermissions() public {
        // An Aqua0 hook deployed at an address without beforeSwap/afterSwap bits fails the v4 address check.
        address bad = address(uint160(0x1234) << 144);
        vm.expectRevert();
        deployCodeTo("Aqua0Hook.sol:Aqua0Hook", abi.encode(manager, slp), bad);
    }
}
