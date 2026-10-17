// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SharedLiquidityPool} from "../src/SharedLiquidityPool.sol";
import {FaucetToken} from "../src/tokens/FaucetToken.sol";
import {HookTemplate} from "../src/examples/HookTemplate.sol";
import {ResidencyScript} from "./utils/ResidencyScript.sol";

/// @title DeployMyHook
/// @notice The resident flow, end to end, against the live residency deployment:
///           1. deploy your hook (mines a valid hook address)          -> shows up in the explorer
///           2. create a mWETH/mUSDC pool that uses it                  -> shows up in the explorer
///           3. faucet test tokens, deposit into the SLP, back your pool
///           4. swap through it
///
///   forge script script/DeployMyHook.s.sol --rpc-url base_sepolia --private-key $PK --broadcast --slow
///
/// Swap `HookTemplate` for your own contract (and its constructor args) below.
contract DeployMyHook is ResidencyScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        string memory json = vm.readFile("deployments/base-sepolia.json");
        SharedLiquidityPool slp =
            SharedLiquidityPool(payable(vm.parseJsonAddress(json, ".contracts.sharedLiquidityPool")));
        address usdc = vm.parseJsonAddress(json, ".tokens.mUSDC");
        address weth = vm.parseJsonAddress(json, ".tokens.mWETH");
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        address me = msg.sender;

        vm.startBroadcast();

        // 1. deploy the hook ------------------------------------------------------------------
        address hook = _deployHook(type(HookTemplate).creationCode, abi.encode(pm, slp), AQUA0_FLAGS);
        console.log("hook deployed", hook);

        // 2. create a pool that uses it (fee 1%, spacing 200, 1 WETH = 3000 USDC) --------------
        PoolKey memory key = _key(weth, usdc, 10_000, 200, hook);
        uint160 price = _sqrtPrice(weth, 1e18, usdc, 3000e6);
        pm.initialize(key, price);
        console.log("pool created");
        console.logBytes32(PoolId.unwrap(key.toId()));

        // 3. test tokens -> SLP -> back the pool ----------------------------------------------
        FaucetToken(usdc).faucet(); // 10,000 mUSDC
        FaucetToken(weth).faucet(); // 10 mWETH
        IERC20(usdc).approve(address(slp), type(uint256).max);
        IERC20(weth).approve(address(slp), type(uint256).max);
        slp.deposit(usdc, 9_000e6, me);
        slp.deposit(weth, 3e18, me);
        (int24 tl, int24 tu) = _range(price, 200, 4000);
        (uint128 liq, uint256 a0, uint256 a1) = _liquidity(key, price, tl, tu, weth, 2e18, 6_000e6);
        slp.addPosition(key, tl, tu, liq, a0, a1, me);

        // 4. swap 100 mUSDC -> mWETH through your hook ----------------------------------------
        IERC20(usdc).approve(POOL_SWAP_TEST, type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == usdc;
        PoolSwapTest(POOL_SWAP_TEST)
            .swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -100e6,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );

        vm.stopBroadcast();

        console.log("swaps counted by your hook:", HookTemplate(payable(hook)).swaps());
        console.log("your SLP mUSDC:", slp.freeBalance(me, usdc) + slp.earnedFees(me, usdc));
        console.log("your SLP mWETH:", slp.freeBalance(me, weth) + slp.earnedFees(me, weth));
    }
}
