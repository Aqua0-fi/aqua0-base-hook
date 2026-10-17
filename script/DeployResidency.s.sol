// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SharedLiquidityPool} from "../src/SharedLiquidityPool.sol";
import {Aqua0Hook} from "../src/hooks/Aqua0Hook.sol";
import {Aqua0Lens} from "../src/periphery/Aqua0Lens.sol";
import {Aqua0QuoteHelper} from "../src/periphery/Aqua0QuoteHelper.sol";
import {TokenFactory} from "../src/tokens/TokenFactory.sol";
import {SwapCounterHook} from "../src/examples/SwapCounterHook.sol";
import {YieldParkingHook} from "../src/examples/YieldParkingHook.sol";
import {MockYieldVault} from "../src/examples/mocks/MockYieldVault.sol";
import {ResidencyScript} from "./utils/ResidencyScript.sol";

/// @title DeployResidency
/// @notice Deploys the whole residency stack on Base Sepolia and seeds it:
///         SLP, default Aqua0Hook, lens, quoter, token factory (+ mUSDC/mWETH/mWBTC),
///         two example hooks, four pools, shared LP positions and a few smoke-test swaps.
///         Writes deployments/base-sepolia.json.
///
///   forge script script/DeployResidency.s.sol --rpc-url base_sepolia --private-key $PK --broadcast --slow
contract DeployResidency is ResidencyScript {
    using PoolIdLibrary for PoolKey;

    struct Ctx {
        address deployer;
        IPoolManager pm;
        SharedLiquidityPool slp;
        Aqua0Hook hook;
        Aqua0Lens lens;
        Aqua0QuoteHelper quoter;
        TokenFactory factory;
        SwapCounterHook counter;
        YieldParkingHook yieldHook;
        MockYieldVault vaultUsdc;
        MockYieldVault vaultWeth;
        address usdc;
        address weth;
        address wbtc;
        PoolKey wethUsdc;
        PoolKey wbtcUsdc;
        PoolKey counterPool;
        PoolKey yieldPool;
        uint256 startBlock;
    }

    function run() external {
        Ctx memory c;
        c.deployer = msg.sender;
        c.pm = IPoolManager(POOL_MANAGER);
        c.startBlock = block.number;
        console.log("deployer", c.deployer);

        vm.startBroadcast();
        _core(c);
        _tokens(c);
        _examples(c);
        _pools(c);
        _seed(c);
        _smokeSwaps(c);
        vm.stopBroadcast();

        _write(c);
    }

    function _core(Ctx memory c) internal {
        c.slp = new SharedLiquidityPool(c.deployer, c.pm);
        c.hook = Aqua0Hook(payable(_deployHook(type(Aqua0Hook).creationCode, abi.encode(c.pm, c.slp), AQUA0_FLAGS)));
        c.lens = new Aqua0Lens(c.slp);
        c.quoter = new Aqua0QuoteHelper(c.slp);
        c.factory = new TokenFactory();
        console.log("SharedLiquidityPool", address(c.slp));
        console.log("Aqua0Hook", address(c.hook));
    }

    function _tokens(Ctx memory c) internal {
        c.usdc = c.factory.createToken("Aqua0 Mock USDC", "mUSDC", 6, 10_000);
        c.weth = c.factory.createToken("Aqua0 Mock WETH", "mWETH", 18, 10);
        c.wbtc = c.factory.createToken("Aqua0 Mock WBTC", "mWBTC", 8, 1);
    }

    function _examples(Ctx memory c) internal {
        c.counter = SwapCounterHook(
            payable(_deployHook(type(SwapCounterHook).creationCode, abi.encode(c.pm, c.slp, 50e18), AQUA0_FLAGS))
        );
        c.yieldHook = YieldParkingHook(
            payable(_deployHook(type(YieldParkingHook).creationCode, abi.encode(c.pm, c.slp, c.deployer), AQUA0_FLAGS))
        );
        c.vaultUsdc = new MockYieldVault(IERC20(c.usdc), "Mock Aave mUSDC", "amUSDC");
        c.vaultWeth = new MockYieldVault(IERC20(c.weth), "Mock Aave mWETH", "amWETH");
        c.yieldHook.setVault(c.usdc, IERC4626(address(c.vaultUsdc)));
        c.yieldHook.setVault(c.weth, IERC4626(address(c.vaultWeth)));
    }

    function _pools(Ctx memory c) internal {
        c.wethUsdc = _key(c.weth, c.usdc, 3000, 60, address(c.hook));
        c.wbtcUsdc = _key(c.wbtc, c.usdc, 3000, 60, address(c.hook));
        c.counterPool = _key(c.weth, c.usdc, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, address(c.counter));
        c.yieldPool = _key(c.weth, c.usdc, 500, 10, address(c.yieldHook));

        uint160 pEth = _sqrtPrice(c.weth, 1e18, c.usdc, 3000e6);
        c.pm.initialize(c.wethUsdc, pEth);
        c.pm.initialize(c.wbtcUsdc, _sqrtPrice(c.wbtc, 1e8, c.usdc, 60_000e6));
        c.pm.initialize(c.counterPool, pEth);
        c.pm.initialize(c.yieldPool, pEth);
    }

    function _seed(Ctx memory c) internal {
        IERC20(c.usdc).approve(address(c.slp), type(uint256).max);
        IERC20(c.weth).approve(address(c.slp), type(uint256).max);
        IERC20(c.wbtc).approve(address(c.slp), type(uint256).max);
        c.slp.deposit(c.usdc, 400_000e6, c.deployer);
        c.slp.deposit(c.weth, 100e18, c.deployer);
        c.slp.deposit(c.wbtc, 4e8, c.deployer);

        // The same 400k mUSDC / 100 mWETH back three WETH pools at once (that is the point of the SLP).
        _allocate(c, c.wethUsdc, c.weth, 50e18, 150_000e6, 6000);
        _allocate(c, c.wethUsdc, c.weth, 20e18, 60_000e6, 600);
        _allocate(c, c.counterPool, c.weth, 40e18, 120_000e6, 3000);
        _allocate(c, c.yieldPool, c.weth, 30e18, 90_000e6, 1000);
        _allocate(c, c.wbtcUsdc, c.wbtc, 2e8, 120_000e6, 6000);

        // The yield hook runs its own treasury that sits in mock Aave vaults between swaps.
        IERC20(c.usdc).approve(address(c.yieldHook), type(uint256).max);
        IERC20(c.weth).approve(address(c.yieldHook), type(uint256).max);
        c.yieldHook.fund(c.usdc, 60_000e6);
        c.yieldHook.fund(c.weth, 20e18);
        uint160 p = c.lens.getPoolState(c.yieldPool.toId()).sqrtPriceX96;
        (int24 tl, int24 tu) = _range(p, 10, 500);
        (uint128 liq,,) = _liquidity(c.yieldPool, p, tl, tu, c.weth, 15e18, 45_000e6);
        c.yieldHook.allocate(c.yieldPool, tl, tu, liq);
    }

    function _allocate(Ctx memory c, PoolKey memory k, address base, uint256 baseAmt, uint256 usdcAmt, int24 width)
        internal
    {
        uint160 p = c.lens.getPoolState(k.toId()).sqrtPriceX96;
        (int24 tl, int24 tu) = _range(p, k.tickSpacing, width);
        (uint128 liq, uint256 a0, uint256 a1) = _liquidity(k, p, tl, tu, base, baseAmt, usdcAmt);
        c.slp.addPosition(k, tl, tu, liq, a0, a1, c.deployer);
    }

    function _smokeSwaps(Ctx memory c) internal {
        IERC20(c.usdc).approve(POOL_SWAP_TEST, type(uint256).max);
        IERC20(c.weth).approve(POOL_SWAP_TEST, type(uint256).max);
        IERC20(c.wbtc).approve(POOL_SWAP_TEST, type(uint256).max);
        _swap(c.wethUsdc, Currency.unwrap(c.wethUsdc.currency0) == c.weth, -1e18); // sell 1 WETH
        _swap(c.wethUsdc, Currency.unwrap(c.wethUsdc.currency0) == c.usdc, -2000e6); // sell 2000 USDC
        _swap(c.counterPool, Currency.unwrap(c.counterPool.currency0) == c.weth, -0.5e18);
        _swap(c.counterPool, Currency.unwrap(c.counterPool.currency0) == c.weth, -0.5e18);
        _swap(c.yieldPool, Currency.unwrap(c.yieldPool.currency0) == c.usdc, -1500e6);
        _swap(c.wbtcUsdc, Currency.unwrap(c.wbtcUsdc.currency0) == c.wbtc, -0.05e8);
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal {
        PoolSwapTest(POOL_SWAP_TEST)
            .swap(
                k,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amount,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
    }

    // ─── JSON ────────────────────────────────────────────────────────────────

    function _write(Ctx memory c) internal {
        string memory j = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "network": "base-sepolia",\n',
            '  "startBlock": ',
            vm.toString(c.startBlock),
            ",\n",
            '  "deployer": "',
            vm.toString(c.deployer),
            '",\n',
            '  "contracts": {\n',
            _kv("poolManager", POOL_MANAGER, false),
            _kv("poolSwapTest", POOL_SWAP_TEST, false),
            _kv("stateView", STATE_VIEW, false),
            _kv("sharedLiquidityPool", address(c.slp), false),
            _kv("aqua0Hook", address(c.hook), false),
            _kv("aqua0Lens", address(c.lens), false),
            _kv("aqua0QuoteHelper", address(c.quoter), false),
            _kv("tokenFactory", address(c.factory), false),
            _kv("swapCounterHook", address(c.counter), false),
            _kv("yieldParkingHook", address(c.yieldHook), false),
            _kv("mockAaveUsdc", address(c.vaultUsdc), false),
            _kv("mockAaveWeth", address(c.vaultWeth), true),
            "  },\n"
        );
        j = string.concat(
            j,
            '  "tokens": {\n',
            _kv("mUSDC", c.usdc, false),
            _kv("mWETH", c.weth, false),
            _kv("mWBTC", c.wbtc, true),
            "  },\n",
            '  "pools": [\n',
            _pool("mWETH/mUSDC 0.30% (Aqua0Hook)", c.wethUsdc, false),
            _pool("mWBTC/mUSDC 0.30% (Aqua0Hook)", c.wbtcUsdc, false),
            _pool("mWETH/mUSDC dynamic (SwapCounterHook)", c.counterPool, false),
            _pool("mWETH/mUSDC 0.05% (YieldParkingHook)", c.yieldPool, true),
            "  ]\n}\n"
        );
        vm.writeFile("deployments/base-sepolia.json", j);
        console.log("wrote deployments/base-sepolia.json");
    }

    function _kv(string memory k, address v, bool last) private pure returns (string memory) {
        return string.concat('    "', k, '": "', vm.toString(v), last ? '"\n' : '",\n');
    }

    function _pool(string memory name, PoolKey memory k, bool last) private pure returns (string memory) {
        return string.concat(
            '    { "name": "',
            name,
            '", "poolId": "',
            vm.toString(PoolId.unwrap(k.toId())),
            '", "currency0": "',
            vm.toString(Currency.unwrap(k.currency0)),
            '", "currency1": "',
            vm.toString(Currency.unwrap(k.currency1)),
            '", "fee": ',
            vm.toString(uint256(k.fee)),
            ', "tickSpacing": ',
            vm.toString(int256(k.tickSpacing)),
            ', "hooks": "',
            vm.toString(address(k.hooks)),
            last ? '" }\n' : '" },\n'
        );
    }
}
