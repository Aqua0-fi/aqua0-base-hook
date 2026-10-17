// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SharedLiquidityPool} from "../../src/SharedLiquidityPool.sol";
import {Aqua0Hook} from "../../src/hooks/Aqua0Hook.sol";

abstract contract Aqua0TestBase is Deployers {
    using StateLibrary for *;

    uint160 internal constant AQUA0_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    SharedLiquidityPool internal slp;
    Aqua0Hook internal hook;
    address internal token0;
    address internal token1;

    address internal lpA = makeAddr("lpA");
    address internal lpB = makeAddr("lpB");
    address internal attacker = makeAddr("attacker");

    uint160 private _hookNonce;

    function _setUpCore() internal {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        token0 = Currency.unwrap(currency0);
        token1 = Currency.unwrap(currency1);
        slp = new SharedLiquidityPool(address(this), manager);
        hook = Aqua0Hook(payable(_deployHook("Aqua0Hook.sol:Aqua0Hook", abi.encode(manager, slp), AQUA0_FLAGS)));
        // Fresh pool, no ordinary liquidity: the PoolManager holds zero reserves of either token.
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    /// @dev Deploys `artifact` at an address whose low bits equal `flags`
    function _deployHook(string memory artifact, bytes memory args, uint160 flags) internal returns (address addr) {
        _hookNonce++;
        addr = address(flags | (_hookNonce << 144));
        deployCodeTo(artifact, args, addr);
    }

    function _deposit(address who, address token, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(who, amount);
            vm.prank(who);
            slp.depositNative{value: amount}(who);
            return;
        }
        MockERC20(token).mint(who, amount);
        vm.startPrank(who);
        MockERC20(token).approve(address(slp), amount);
        slp.deposit(token, amount, who);
        vm.stopPrank();
    }

    function _liquidityFor(PoolKey memory k, int24 tl, int24 tu, uint256 a0, uint256 a1)
        internal
        view
        returns (uint128)
    {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(manager, k.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), a0, a1
        );
    }

    function _addPosition(address who, PoolKey memory k, int24 tl, int24 tu, uint256 a0, uint256 a1)
        internal
        returns (uint128 liq)
    {
        liq = _liquidityFor(k, tl, tu, a0, a1);
        vm.prank(who);
        slp.addPosition(k, tl, tu, liq, a0, a1, who);
    }

    function _holdings(address token) internal view returns (uint256) {
        return slp.totalHoldings(token);
    }

    function _assertSolvent(address token) internal view {
        assertGe(slp.totalHoldings(token), slp.totalLiabilities(token), "SLP insolvent");
    }

    function _assertHookClean(address h, PoolKey memory k) internal view {
        // the hook must not be left holding claims or tokens after a swap (exact settlement)
        assertEq(manager.balanceOf(h, k.currency0.toId()), 0, "hook kept claims0");
        assertEq(manager.balanceOf(h, k.currency1.toId()), 0, "hook kept claims1");
        assertEq(k.currency0.balanceOf(h), 0, "hook kept token0");
        assertEq(k.currency1.balanceOf(h), 0, "hook kept token1");
    }

    function _total(address who, address token) internal view returns (uint256) {
        return slp.freeBalance(who, token) + slp.earnedFees(who, token);
    }
}
