# Aqua0 Base Hook

**Build Uniswap v4 hooks on top of Aqua0 shared liquidity.** One LP deposit backs every pool whose hook extends `Aqua0BaseHook`. Liquidity is lent to a pool for the duration of a single swap, then handed back with the LP's share of the trade and the fee.

This is the residency build for **Edge City × Aqua0**, deployed on **Base Sepolia**.

> [!WARNING]
> **Residency sandbox, read before building**
> - **Unaudited.** Testnet only. Do not put real funds anywhere near this.
> - **Uniswap v4 only, single chain.** The cross-chain filler and rebalancing from the full Aqua0 protocol are **not** included.
> - **The final Aqua0 protocol will change.** The Uniswap v4 hook surface (`Aqua0BaseHook` and its three calls) will stay similar, so what you build here should port with small changes.
> - **Aqua (1inch) support is coming** next to the Uniswap v4 integration.

| | |
|---|---|
| Explorer (auto-indexes every Aqua0 hook and pool) | **https://aqua0-base-hook.vercel.app** |
| Network | Base Sepolia (chain id 84532) |
| Addresses | [`deployments/base-sepolia.json`](deployments/base-sepolia.json) |
| Build a hook | [`docs/BUILDING_HOOKS.md`](docs/BUILDING_HOOKS.md) |
| Integrate with the SLP | [`docs/USING_THE_SLP.md`](docs/USING_THE_SLP.md) |
| Provide liquidity (users) | [`docs/LP_GUIDE.md`](docs/LP_GUIDE.md) |

---

## 60-second version

```solidity
contract MyHook is Aqua0BaseHook {               // instead of Uniswap's BaseHook
    constructor(IPoolManager pm, SharedLiquidityPool slp) Aqua0BaseHook(pm, slp) {}

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        _addVirtualLiquidity(key);                       // 1. shared liquidity in
        // your logic
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        (bool hasJIT,) = _removeVirtualLiquidity(key);   // 2. shared liquidity out
        if (hasJIT) _settleVirtualLiquidityDeltas(key);  // 3. settle with the SLP
        // your logic
        return (IHooks.afterSwap.selector, 0);
    }
}
```

`Aqua0BaseHook` **is** a Uniswap v4 `BaseHook` ([OpenZeppelin uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks)), so everything you know about v4 hooks applies. The default `_beforeSwap` / `_afterSwap` already make the three calls, so an empty contract is a working Aqua0 hook.

```bash
git clone --recurse-submodules https://github.com/Aqua0-fi/aqua0-base-hook
cd aqua0-base-hook
forge test                                   # 32 tests: core, security, examples, fuzz

# deploy src/examples/HookTemplate.sol, create a pool, back it, swap, all on Base Sepolia
forge script script/DeployMyHook.s.sol --rpc-url https://sepolia.base.org \
  --private-key $TESTNET_PK --broadcast
```

Your hook appears in the explorer within seconds. It registers itself with the SLP from its constructor, and pools are picked up from the PoolManager's `Initialize` events. Nothing to submit.

---

## How it works

```
 LPs ──deposit──▶  SharedLiquidityPool (SLP)  ◀── addPosition(pool, range): virtual, nothing moves
                         │      ▲
           preSwap ranges│      │ book each LP's share; settle the net
                         ▼      │
  swap ──▶ PoolManager ──▶ YourHook (extends Aqua0BaseHook)
              beforeSwap: _addVirtualLiquidity    → mint JIT liquidity in the PoolManager
              (swap runs against it)
              afterSwap:  _removeVirtualLiquidity → burn it, SLP books the result
                          _settleVirtualLiquidityDeltas → pay the PoolManager the net
```

- **One balance, many pools.** An LP's free balance is not locked by `addPosition`. The same tokens can back ranges in every pool at once. At swap time, each LP's liquidity is scaled so its worst-case loss fits in its current balance.
- **Only the net moves.** Liquidity is added and removed inside the same swap. Only the net token change is settled. Gains reach the SLP as PoolManager ERC6909 claims, so swaps work even on fresh testnet tokens the PoolManager holds no reserves of. Claims are redeemed automatically on withdraw.
- **The SLP trusts PoolManager state, not hooks.** For every swap it recomputes the mint cost, burn proceeds and LP fees from PoolManager state, using the same math v4-core uses. It then checks that its liabilities grew no faster than its holdings. A buggy or hostile hook can make its own swaps revert, but it can't misreport a result.

## What's deployed (Base Sepolia)

| Contract | Address |
|---|---|
| SharedLiquidityPool | `0x3387fDCf3B8A8a935C9627f033f94Df1cbAbC700` |
| Aqua0Hook (default, no custom logic) | `0x28ee0516a4AF45b5DFA7037C5A5CE9e608D500c0` |
| SwapCounterHook (example) | `0x8819d712dAf2963d64285698FeB35f82919780C0` |
| YieldParkingHook (example) | `0x4f2cE7f53622B26EEEA5Af9C86F15C16B37000C0` |
| Aqua0Lens (read helpers) | `0x1cd30dcaefba04143088a3eB14978839E5AEdbeA` |
| Aqua0QuoteHelper | `0x25D6437843d2F711199489eAA47A6596cc888D54` |
| TokenFactory (token + faucet) | `0x6d23269949781f859c1eeBD429D85Df735a7FE28` |
| mUSDC / mWETH / mWBTC (faucet tokens) | `0xdA00a9D793a863c79033C89707Fce1b9eE959a05` / `0xBD6b1A82837932DFC5a2CCaf837f1c16f0fdd5FB` / `0x55CE234871d999F0D14D244Ee8ce63a9d384C6Ae` |
| Uniswap v4 PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Uniswap PoolSwapTest (router) | `0x8B5bcC363ddE2614281aD875bad385E0A785D3B9` |

Four pools are live and seeded with shared liquidity: mWETH/mUSDC on the default hook, on SwapCounterHook (dynamic fee) and on YieldParkingHook, plus mWBTC/mUSDC. The full list with pool ids is in [`deployments/base-sepolia.json`](deployments/base-sepolia.json).

Gas: get Base Sepolia ETH from the [Coinbase](https://portal.cdp.coinbase.com/products/faucet), [Alchemy](https://www.alchemy.com/faucets/base-sepolia) or [Superchain](https://console.optimism.io/faucet) faucets. Test tokens: call `faucet()` on any factory token, or use the explorer's **Tokens & faucet** tab, where anyone can also launch their own token.

## Repo layout

```
src/
  Aqua0BaseHook.sol          extend this (it extends OZ/Uniswap BaseHook)
  SharedLiquidityPool.sol    the SLP: deposits, positions, JIT sizing, settlement
  hooks/Aqua0Hook.sol        default hook, no custom logic
  examples/
    HookTemplate.sol         copy me
    SwapCounterHook.sol      silly custom logic: swap cap, counter, happy-hour dynamic fee
    YieldParkingHook.sol     idle funds sit in an ERC4626 vault (Aave/Ondo-style), JIT into the SLP per swap
    mocks/MockYieldVault.sol
  periphery/                 Aqua0Lens (views), Aqua0QuoteHelper (quotes incl. hooks)
  tokens/                    TokenFactory + FaucetToken
test/                        core, security, examples, shared-across-pools, fuzz
script/
  DeployResidency.s.sol      the full residency deployment (already run)
  DeployMyHook.s.sol         resident flow: deploy hook -> pool -> deposit -> back -> swap
app/                         explorer: static React + viem site, indexes in the browser
Dockerfile                   explorer image (edge-city-aqua0-residency)
```

## Tests

```bash
forge test            # all
forge test -vv --mc SharedAcrossPoolsTest   # one deposit backing four pools on three different hooks
forge test -vv --mc SecurityTest            # replays the attacks that broke the cohort-8 version
```

What's covered:
- swaps on a fresh pool with no PoolManager reserves, both directions, exact-in and exact-out, native ETH
- multi-LP pro-rata accounting, fees, under-funded LPs being scaled down
- one deposit backing four pools on three hooks
- both example hooks
- the token factory
- hostile contracts and hooks
- a fuzz run checking that every swap settles to the wei and the SLP stays solvent

## Changes from the UHI cohort-8 version

This started from `contracts-hookathon` (UHI8). Before opening it up to other builders, the following were fixed. Each has a test in [`test/Security.t.sol`](test/Security.t.sol) or [`test/Aqua0Hook.t.sol`](test/Aqua0Hook.t.sol).

| Problem in the original | Fix |
|---|---|
| Any contract answering the ERC165 marker could call `settleSwapDelta` and drain the whole pool, or `withdraw` any LP's balance | Only owners or approved operators touch balances. A hook can only open a session for a pool where it is `key.hooks`. Hook-supplied amounts are no longer trusted |
| Swaps reverted on fresh pools: the hook `take`s the swapper's input before the swapper has paid | Gains are delivered as ERC6909 claims, which need no PoolManager reserves |
| Positions declared with 0/0 reserves were injected at full size, letting an LP trade against other LPs' funds | Each LP is sized against its real free balance at the current price |
| Invalid ticks, or a range scaled to zero liquidity, made every swap in the pool revert | Ticks validated on `addPosition`; empty ranges skipped |
| Unbounded loops over ranges and users | Capped per pool and per range; slots freed on `removePosition` |
| `_settleVirtualLiquidityDeltas` settled the hook's whole PoolManager delta, swallowing a hook's own fees/return deltas | Settles only the virtual-liquidity part |
| `Aqua0BaseHook` was a mixin; hooks implemented all 14 `IHooks` functions by hand | Extends OZ `BaseHook`; defaults for swap callbacks; registers itself for indexing |

## Explorer

`app/` is a static site with no backend. The browser reads logs from a public Base Sepolia RPC and caches them in `localStorage`. It discovers:
- every hook that registered with the SLP (`HookRegistered`)
- every v4 pool whose hook passes the Aqua0 ERC165 check (`PoolManager.Initialize`)
- deposits, positions, swaps and factory tokens

```bash
cd app && npm install && npm run dev          # http://localhost:8787
docker build -t edge-city-aqua0-residency . && docker run -p 8787:80 edge-city-aqua0-residency
```

## License

MIT. Unaudited software provided as is, for testnet experimentation.
