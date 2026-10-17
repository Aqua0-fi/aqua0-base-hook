// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Shared helpers for the residency scripts (Base Sepolia)
abstract contract ResidencyScript is Script {
    // Uniswap v4 on Base Sepolia (https://docs.uniswap.org/contracts/v4/deployments)
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant STATE_VIEW = 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4;

    uint160 internal constant AQUA0_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    /// @dev Mines a CREATE2 salt so the address carries `flags`, then deploys through the deterministic deployer.
    function _deployHook(bytes memory creationCode, bytes memory args, uint160 flags) internal returns (address hook) {
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, flags, creationCode, args);
        bytes memory initCode = abi.encodePacked(creationCode, args);
        assembly ("memory-safe") {
            hook := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(hook == predicted, "hook address mismatch");
    }

    /// @dev Sorted PoolKey for two ERC20s
    function _key(address a, address b, uint24 fee, int24 spacing, address hooks)
        internal
        pure
        returns (PoolKey memory k)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hooks)
        });
    }

    /// @dev sqrtPriceX96 such that `rawA` units of `a` are worth `rawB` units of `b`
    function _sqrtPrice(address a, uint256 rawA, address b, uint256 rawB) internal pure returns (uint160) {
        (uint256 amount0, uint256 amount1) = a < b ? (rawA, rawB) : (rawB, rawA);
        return uint160(Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0)));
    }

    /// @dev Range of +-`width` ticks around the current price, aligned to spacing
    function _range(uint160 sqrtPriceX96, int24 spacing, int24 width) internal pure returns (int24 lower, int24 upper) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 aligned = (tick / spacing) * spacing;
        lower = aligned - width;
        upper = aligned + width;
    }

    function _liquidity(
        PoolKey memory k,
        uint160 sqrtPriceX96,
        int24 tl,
        int24 tu,
        address a,
        uint256 amtA,
        uint256 amtB
    ) internal pure returns (uint128 liq, uint256 amount0, uint256 amount1) {
        (amount0, amount1) = Currency.unwrap(k.currency0) == a ? (amtA, amtB) : (amtB, amtA);
        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), amount0, amount1
        );
    }
}
