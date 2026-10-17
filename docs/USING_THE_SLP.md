# Using the Shared Liquidity Pool (SLP)

> Unaudited residency build · Uniswap v4 only · single chain · Base Sepolia.

`SharedLiquidityPool` holds every LP's tokens and lends them to Aqua0 hooks one swap at a time. This page is the reference for anything that talks to it: frontends, vaults, routers, bots.

Address on Base Sepolia: `0x3387fDCf3B8A8a935C9627f033f94Df1cbAbC700` (see [`deployments/base-sepolia.json`](../deployments/base-sepolia.json)).

## Mental model

```
freeBalance[user][token]     withdrawable now. Swaps that use your liquidity move tokens in and out of it.
earnedFees[user][token]      LP fees, claimed separately
userPositions[user][id]      (pool, tickLower, tickUpper, liquidity) you back. Virtual: nothing is locked.
```

- `deposit` adds to `freeBalance`. `addPosition` doesn't touch it.
- The same `freeBalance` can back positions in many pools (that's the amplification). At every swap, the SLP sizes your liquidity so its cost at the current price fits in your free balance, minus what other ranges in the same swap already used. If you withdraw, your positions shrink automatically. They never draw on other LPs' funds.
- After a swap, your share of the trade lands in `freeBalance` (+input token, −output token) and your share of the fee in `earnedFees`.

## LP functions

```solidity
function deposit(address token, uint256 amount, address to) external;         // ERC20; approve first
function depositNative(address to) external payable;                         // ETH, booked under address(0)
function withdraw(address token, uint256 amount, address from, address to) external;
function claimFees(address token, address from, address to) external;
function setOperator(address operator, bool approved) external;              // let a contract act for you

function addPosition(
    PoolKey calldata key,      // pool must be initialized and its hook must be an Aqua0 hook
    int24 tickLower,           // multiple of key.tickSpacing
    int24 tickUpper,
    uint128 liquidity,         // v4 liquidity units (use Aqua0Lens.liquidityForAmounts)
    uint256 token0Amount,      // informational earmark; must be <= your free balance
    uint256 token1Amount,
    address owner              // you, or someone who made you their operator
) external returns (bytes32 positionId);

function removePosition(PoolKey calldata key, int24 tickLower, int24 tickUpper, address owner) external;
```

`from` / `owner` must be `msg.sender` or an address that approved `msg.sender` with `setOperator`. Nothing else can move a user's balance.

One position per (owner, pool, range); to change it, remove and re-add. Ticks must be multiples of the pool's tick spacing and within the usable range.

### Getting `liquidity` right

Use the lens. It reads the current price and gives you the liquidity plus the amounts it really uses:

```solidity
(uint128 liquidity, uint256 used0, uint256 used1) =
    lens.liquidityForAmounts(poolId, tickLower, tickUpper, maxAmount0, maxAmount1);
slp.addPosition(key, tickLower, tickUpper, liquidity, used0, used1, msg.sender);
```

## Views

```solidity
freeBalance(user, token) · earnedFees(user, token)
getUserPositionIds(user) · userPositions(user, positionId)
getPoolRanges(poolId) → RangeInfo[]  (tickLower, tickUpper, totalLiquidity) aggregated over LPs
getPoolRangeKeys(poolId) · getRangeUsers(poolId, rangeKey)
liquidBalance(token)   tokens held directly
claimBalance(token)    PoolManager ERC6909 claims held (redeemed on withdraw)
totalHoldings(token)   liquid + claims
totalLiabilities(token) sum of all freeBalance + earnedFees   (holdings >= liabilities, always)
getRegisteredHooks() · isRegisteredHook(hook)
paused() · maxRangesPerPool() · maxUsersPerRange()
```

[`Aqua0Lens`](../src/periphery/Aqua0Lens.sol) (`0x1cd30dcaefba04143088a3eB14978839E5AEdbeA`) bundles the common reads: `getPoolState`, `liquidityForAmounts`, `amountsForLiquidity`, `getUserPositions` (with current token amounts), `getUserBalances`, `getPoolHoldings`.

[`Aqua0QuoteHelper`](../src/periphery/Aqua0QuoteHelper.sol) (`0x25D6437843d2F711199489eAA47A6596cc888D54`) simulates a swap with all hooks running and reverts with `Quote(amount0, amount1, slpDelta0, slpDelta1)`. Call it via `eth_call` and decode the error.

## Events

```solidity
event Deposited(address indexed user, address indexed token, uint256 amount);
event Withdrawn(address indexed user, address indexed token, uint256 amount, address to);
event FeesClaimed(address indexed user, address indexed token, uint256 amount, address to);
event OperatorSet(address indexed owner, address indexed operator, bool approved);
event PositionAdded(address indexed user, bytes32 indexed positionId, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
event PositionRemoved(address indexed user, bytes32 indexed positionId, PoolId indexed poolId);
event HookRegistered(address indexed hook, address indexed deployer);    // from every Aqua0BaseHook constructor
event SwapAccounted(PoolId indexed poolId, address indexed hook, int256 net0, int256 net1, uint256 fees0, uint256 fees1);
```

To discover Aqua0 hooks and pools (what the explorer does):
1. `HookRegistered` on the SLP: every hook deployed on `Aqua0BaseHook`. Unverified, so check `supportsInterface(0x46debb1f)` and `sharedPool()` before trusting it.
2. `Initialize` on the PoolManager: keep pools whose `hooks` passes the same check.

## Hook protocol (what `Aqua0BaseHook` does for you)

Every swap that uses shared liquidity runs a three-step session, keyed by pool, in transient storage:

| Step | Caller | SLP does |
|---|---|---|
| `preSwap(key)` | the pool's hook (`msg.sender == key.hooks`) | Sizes every LP against its budget at the current price and returns ranges. Records the expected mint cost. |
| hook mints the ranges | | |
| *swap* | | |
| `checkpoint(key)` | same hook | Reads the hook's JIT positions from the PoolManager: checks the liquidity is really there, and computes burn proceeds and fees exactly as v4-core will. |
| hook burns; mints ERC6909 claims for net gains and approves the SLP | | |
| `postSwap(key)` → `Payout` | same hook | Books each LP's share, checks liabilities did not outgrow holdings, pulls the gain claims, and pays the net loss to the hook (claims first, then tokens). |
| hook pays the PoolManager (`_settleVirtualLiquidityDeltas`) | | |

While a session is open, `withdraw`, `claimFees`, `addPosition` and `removePosition` revert with `SwapInProgress`. Deposits are allowed, because hooks like `YieldParkingHook` deposit just before borrowing.

## Trust model

| Who | Can | Cannot |
|---|---|---|
| LP | deposit, withdraw own funds at any time (even when paused), choose which pools to back | spend another LP's balance; unbacked liquidity is scaled to zero |
| Operator (opt-in per owner) | act for that owner | act mid-swap |
| Any hook | open sessions for pools where it is `key.hooks` | touch pools it isn't the hook of; report its own numbers (the SLP reads the PoolManager) |
| SLP owner (Aqua0) | `setPaused` (stops new deposits/positions; swaps run without shared liquidity), `setLimits` | move or freeze LP funds; withdrawals are never paused |

Backing a pool still means trusting its hook to some degree, as with any v4 pool. A hook decides how swaps reach your liquidity (fees, gating). It cannot fake the results.

## Known limitations (residency build)

- Unaudited. Rounding dust (a few wei per swap) stays in the SLP as surplus.
- The LP-fee vs inventory split comes from v4 fee growth, so it is exact. Price risk (impermanent loss) is the LP's, as with any v4 position.
- A pool can hold at most 16 ranges with 16 LPs each. Someone can fill a pool's slots with dust positions; the owner can raise the limits.
- One position per (owner, pool, range).
- No cross-chain filler, rebalancer or Aqua integration in this build.
