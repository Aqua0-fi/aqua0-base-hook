// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Aqua0TestBase} from "./utils/Aqua0TestBase.sol";

/// @notice Random swap sequences: every swap settles exactly and the SLP stays solvent
contract SolvencyFuzzTest is Aqua0TestBase {
    function setUp() public {
        _setUpCore();
        _deposit(lpA, token0, 500e18);
        _deposit(lpA, token1, 500e18);
        _deposit(lpB, token0, 50e18);
        _deposit(lpB, token1, 300e18);
        _addPosition(lpA, key, -600, 600, 200e18, 200e18);
        _addPosition(lpA, key, -6000, 6000, 200e18, 200e18);
        _addPosition(lpB, key, -120, 120, 40e18, 40e18);
        // over-allocated: liquidity worth 400/400 backed by 50/300, gets scaled at swap time
        uint128 big = _liquidityFor(key, -3000, 600, 400e18, 400e18);
        vm.prank(lpB);
        slp.addPosition(key, -3000, 600, big, 50e18, 300e18, lpB);
    }

    function testFuzz_swapsKeepSolvency(uint256 seed) public {
        for (uint256 i = 0; i < 10; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = seed & 1 == 1;
            bool exactIn = seed & 2 == 2;
            uint256 size = bound(seed >> 8, 1e9, 60e18);
            int256 amount = exactIn ? -int256(size) : int256(size / 4);
            swap(key, zeroForOne, amount, ZERO_BYTES);

            _assertSolvent(token0);
            _assertSolvent(token1);
            _assertHookClean(address(hook), key);
            assertGe(slp.liquidBalance(token0) + slp.claimBalance(token0), slp.totalLiabilities(token0));
        }
    }
}
