# Building hooks on Aqua0

> Unaudited residency build · Uniswap v4 only · single chain (no cross-chain filler) · Base Sepolia.
> The final Aqua0 protocol will change; this hook surface will stay similar. Aqua (1inch) support is coming.

If you have written a Uniswap v4 hook, you already know 95% of this. `Aqua0BaseHook` extends OpenZeppelin's `BaseHook` (the standard v4 hook base) and adds three internal functions. Call them in your swap callbacks and every LP in the Shared Liquidity Pool who backs your pool trades through it.

## 1. Setup

```bash
git clone --recurse-submodules https://github.com/Aqua0-fi/aqua0-base-hook
cd aqua0-base-hook
forge build && forge test
```

Foundry with solc 0.8.26 (cancun, via-ir). Dependencies come in through `lib/uniswap-hooks` (v4-core, v4-periphery, OpenZeppelin).

## 2. The three calls

| Call | Where | What it does |
|---|---|---|
| `_addVirtualLiquidity(key)` | `_beforeSwap` | Asks the SLP which ranges LPs are backing in this pool, sized to their balances, and mints that liquidity into the PoolManager (salt `Aqua0Constants.JIT_SALT`). |
| `_removeVirtualLiquidity(key)` → `(bool hasJIT, uint24 lpFee)` | `_afterSwap`, first | Burns that liquidity. The SLP books every LP's share of the trade and the fees. Gains go to the SLP as ERC6909 claims; losses are paid to your hook. |
| `_settleVirtualLiquidityDeltas(key)` | `_afterSwap`, if `hasJIT` | Pays the PoolManager what the virtual liquidity owes, using what the SLP sent. |

The defaults in `Aqua0BaseHook` do exactly this, so you only override what you need:

```solidity
contract Aqua0Hook is Aqua0BaseHook {
    constructor(IPoolManager pm, SharedLiquidityPool slp) Aqua0BaseHook(pm, slp) {}
}
```

## 3. Your own hook

Start from [`src/examples/HookTemplate.sol`](../src/examples/HookTemplate.sol):

```solidity
contract MyHook is Aqua0BaseHook {
    constructor(IPoolManager pm, SharedLiquidityPool slp) Aqua0BaseHook(pm, slp) {}

    function hookName() public pure override returns (string memory) {
        return "MyHook";                                     // explorer label (optional)
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;                                 // required
        p.afterSwap = true;                                  // required
        p.afterInitialize = true;                            // anything else you need
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        // checks that may reject the swap go first, before liquidity is borrowed
        _addVirtualLiquidity(key);
        // logic that relies on pool depth goes after
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        (bool hasJIT,) = _removeVirtualLiquidity(key);
        if (hasJIT) _settleVirtualLiquidityDeltas(key);
        // post-swap logic
        return (IHooks.afterSwap.selector, 0);
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }
}
```

Rules:
1. **Keep `beforeSwap` and `afterSwap` on.** The constructor reverts with `Aqua0RequiresSwapHooks` otherwise.
2. **Always pair add with remove + settle** in the same swap, or the PoolManager reverts with `CurrencyNotSettled`.
3. **The hook address encodes its permissions.** In v4, the low 14 bits of a hook's address must equal its permission flags. `script/DeployMyHook.s.sol` mines a CREATE2 salt with `HookMiner` for you. If you change permissions, change `AQUA0_FLAGS` in the script to match.
4. **Your own deltas are yours.** Fees taken through `beforeSwapReturnDelta`/`afterSwapReturnDelta`, or liquidity you add yourself (salt ≠ `JIT_SALT`), are not touched by the helpers.
5. **Dynamic fees work.** Create the pool with `LPFeeLibrary.DYNAMIC_FEE_FLAG` and return `fee | OVERRIDE_FEE_FLAG` from `_beforeSwap`. LPs are credited the fee actually charged. See `SwapCounterHook`.

## 4. Deploy and test it live

```bash
export TESTNET_PK=0x...   # a throwaway key with a little Base Sepolia ETH
forge script script/DeployMyHook.s.sol --rpc-url https://sepolia.base.org --private-key $TESTNET_PK --broadcast
```

The script reads `deployments/base-sepolia.json` and:
1. deploys `HookTemplate` (swap in your contract) at a mined address
2. creates a mWETH/mUSDC pool on it
3. mints test tokens from the faucet, deposits them into the SLP and backs a ±50% range
4. swaps 100 mUSDC through your hook

Open the explorer: your hook shows up as soon as its constructor runs, and the pool as soon as it is initialized.

## 5. Test locally

`test/utils/Aqua0TestBase.sol` sets up a fresh PoolManager, the SLP, a default hook, and helpers for deploying a hook at a flagged address, depositing and adding positions:

```solidity
contract MyHookTest is Aqua0TestBase {
    function setUp() public {
        _setUpCore();
        MyHook h = MyHook(payable(_deployHook("MyHook.sol:MyHook", abi.encode(manager, slp), AQUA0_FLAGS)));
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(h)), 3000, SQRT_PRICE_1_1);
        _deposit(lpA, token0, 100e18);
        _deposit(lpA, token1, 100e18);
        _addPosition(lpA, k, -600, 600, 50e18, 50e18);
    }
}
```

Useful assertions: `_assertSolvent(token)` (SLP holds at least what it owes) and `_assertHookClean(hook, key)` (the hook kept no stray claims or tokens).

## 6. Patterns

### Your hook as an LP: `YieldParkingHook`
Your hook can hold funds and be an LP itself: `sharedPool.deposit(token, amt, address(this))` then `sharedPool.addPosition(..., address(this))`. [`YieldParkingHook`](../src/examples/YieldParkingHook.sol) keeps idle capital in an ERC4626 vault (stand-in for Aave, or an Ondo-style yield token) and only moves it into the SLP for the length of a swap:

```
beforeSwap: vault.redeem → sharedPool.deposit → _addVirtualLiquidity
afterSwap:  _removeVirtualLiquidity → _settleVirtualLiquidityDeltas → sharedPool.withdraw → vault.deposit
```

One subtlety: gains from the swap that just happened arrive as PoolManager claims. They can only be redeemed once the swapper has paid, which happens after `afterSwap`. So mid-swap, withdraw at most `sharedPool.liquidBalance(token)`. Anything left is withdrawn later (the example's `sweep`), outside a swap.

For a multi-step version of this (e.g. Ondo USDY → swap to USDC → Aave), put the conversions in the same two places: unwind before `_addVirtualLiquidity`, re-wrap after settle. Keep the conversions slippage-safe; this example has no slippage protection.

### Gating swaps
Revert in `_beforeSwap` **before** `_addVirtualLiquidity` (KYC, allowlists, size caps). See `SwapCounterHook.maxSwapSize`.

### Acting for users
Users can approve your hook or router as an SLP operator (`sharedPool.setOperator(hook, true)`), which lets it deposit, withdraw and manage positions on their behalf. Operators cannot move funds while a swap is in progress.

## 7. What the SLP enforces (so you know what will revert)

| Revert | Why |
|---|---|
| `CallerNotPoolHook` | `preSwap` called by something other than `key.hooks` |
| `NoOpenSession` | `checkpoint`/`postSwap` out of order, or by another contract |
| `VirtualLiquidityMissing` | The JIT liquidity is not actually in the PoolManager at checkpoint |
| `SwapInProgress` | `withdraw`, `claimFees`, `addPosition` or `removePosition` between `preSwap` and `postSwap` |
| `Insolvent` | A swap's result would leave the SLP owing more than it holds (should never fire) |
| `NotAqua0Hook` | `addPosition` on a pool whose hook doesn't pass the ERC165 marker |

## 8. Gas

A swap through one shared range costs about 480k gas, against roughly 130k for a plain v4 swap. Each extra range adds a mint, a burn and a few transient-storage reads. The SLP caps a pool at 16 ranges with 16 LPs per range (the owner can change this).
