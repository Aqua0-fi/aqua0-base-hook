// In-browser indexer. No backend: reads logs straight from a public RPC and caches state in localStorage.
//
// Discovery:
//   - SharedLiquidityPool.HookRegistered  -> every hook extending Aqua0BaseHook registers itself in its constructor
//   - PoolManager.Initialize              -> any v4 pool whose hook passes the Aqua0 ERC165 marker check
//   - PoolManager.Swap (those pools)      -> volume
//   - SLP events                          -> deposits, positions, JIT swaps
//   - TokenFactory.TokenCreated           -> faucet tokens
import { decodeEventLog, getAddress, zeroAddress } from "viem";
import { publicClient as client, deployments, C } from "./config.js";
import { slpAbi, lensAbi, factoryAbi, erc20Abi, hookAbi, poolManagerAbi, AQUA0_MARKER_ID } from "./abis.js";

const VERSION = 2;
const STORAGE_KEY = `aqua0-residency:${deployments.chainId}:${C.sharedLiquidityPool.toLowerCase()}:v${VERSION}`;
const CHUNK = 45_000n;
const CONFIRMATIONS = 1n;
const LIVE_EVERY_MS = 12_000;

const lc = (a) => a.toLowerCase();
const str = (v) => (typeof v === "bigint" ? v.toString() : v);
const initEvent = poolManagerAbi.find((x) => x.name === "Initialize");
const swapEvent = poolManagerAbi.find((x) => x.name === "Swap");
const tokenCreatedEvent = factoryAbi.find((x) => x.name === "TokenCreated");

function emptyState() {
  return {
    lastBlock: (BigInt(deployments.startBlock) - 1n).toString(),
    hooks: {},
    pools: {},
    tokens: {},
    lps: {},
    activity: [],
    totals: { swaps: 0, aqua0Swaps: 0, deposits: 0, positions: 0 },
    slp: { tokens: {} },
  };
}

function load() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) return { ...emptyState(), ...JSON.parse(raw) };
  } catch {}
  return emptyState();
}

async function tryRead(address, abi, functionName, args = []) {
  try {
    return await client.readContract({ address, abi, functionName, args });
  } catch {
    return undefined;
  }
}

function decode(abi, log) {
  try {
    return decodeEventLog({ abi, data: log.data, topics: log.topics });
  } catch {
    return null;
  }
}

const byOrder = (x, y) =>
  x.blockNumber === y.blockNumber ? x.logIndex - y.logIndex : Number(x.blockNumber - y.blockNumber);

export class Indexer {
  constructor() {
    this.state = load();
    this.listeners = new Set();
    this.status = { syncing: false, headBlock: null, error: null };
    this.lastLive = 0;
    this.timer = null;
  }

  subscribe(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  emit() {
    this.snapshot = { ...this.state, status: { ...this.status } };
    for (const fn of this.listeners) fn(this.snapshot);
  }

  persist() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.state));
    } catch {}
  }

  start(pollMs = 6000) {
    if (this.timer) return;
    this.emit();
    this.sync();
    this.timer = setInterval(() => this.sync(), pollMs);
  }

  reset() {
    this.state = emptyState();
    this.lastLive = 0;
    this.persist();
    this.emit();
    this.sync();
  }

  pushActivity(item) {
    this.state.activity.unshift(item);
    if (this.state.activity.length > 250) this.state.activity.length = 250;
  }

  async ensureToken(address) {
    const key = lc(address);
    if (this.state.tokens[key]) return this.state.tokens[key];
    if (address === zeroAddress) {
      return (this.state.tokens[key] = { address, name: "Ether", symbol: "ETH", decimals: 18, native: true });
    }
    const [name, symbol, decimals] = await Promise.all([
      tryRead(address, erc20Abi, "name"),
      tryRead(address, erc20Abi, "symbol"),
      tryRead(address, erc20Abi, "decimals"),
    ]);
    return (this.state.tokens[key] = {
      address: getAddress(address),
      name: name ?? "Unknown",
      symbol: symbol ?? address.slice(0, 8),
      decimals: decimals ?? 18,
    });
  }

  async ensureHook(address, extra = {}, force = false) {
    const key = lc(address);
    const existing = this.state.hooks[key];
    if (existing && existing.isAqua0 && !force) return Object.assign(existing, extra);
    const [isAqua0, name, sharedPool, poolManager] = await Promise.all([
      tryRead(address, hookAbi, "supportsInterface", [AQUA0_MARKER_ID]),
      tryRead(address, hookAbi, "hookName"),
      tryRead(address, hookAbi, "sharedPool"),
      tryRead(address, hookAbi, "poolManager"),
    ]);
    const rec = {
      pools: [],
      swaps: 0,
      deployer: null,
      registeredBlock: null,
      registeredTx: null,
      ...existing,
      address: getAddress(address),
      name: name || "Unnamed hook",
      isAqua0: isAqua0 === true,
      connected:
        !!sharedPool && lc(sharedPool) === lc(C.sharedLiquidityPool) && lc(poolManager || "") === lc(C.poolManager),
      sharedPool: sharedPool ? getAddress(sharedPool) : null,
      official: Object.entries(C).find(([, v]) => lc(v) === key)?.[0] ?? null,
      ...extra,
    };
    return (this.state.hooks[key] = rec);
  }

  async handleSlp(log) {
    const ev = decode(slpAbi, log);
    if (!ev) return;
    const a = ev.args;
    const st = this.state;
    const base = { block: Number(log.blockNumber), tx: log.transactionHash };
    const lp = (u) => (st.lps[lc(u)] ||= { address: getAddress(u), deposits: 0, positionsActive: 0 });
    switch (ev.eventName) {
      case "HookRegistered": {
        const h = await this.ensureHook(
          a.hook,
          { deployer: getAddress(a.deployer), registeredBlock: base.block, registeredTx: base.tx },
          true
        );
        this.pushActivity({ ...base, type: "hook", hook: h.address, name: h.name, deployer: h.deployer });
        break;
      }
      case "Deposited":
        await this.ensureToken(a.token);
        lp(a.user).deposits++;
        st.totals.deposits++;
        this.pushActivity({ ...base, type: "deposit", user: getAddress(a.user), token: getAddress(a.token), amount: str(a.amount) });
        break;
      case "Withdrawn":
        this.pushActivity({ ...base, type: "withdraw", user: getAddress(a.user), token: getAddress(a.token), amount: str(a.amount) });
        break;
      case "FeesClaimed":
        this.pushActivity({ ...base, type: "claim", user: getAddress(a.user), token: getAddress(a.token), amount: str(a.amount) });
        break;
      case "PositionAdded": {
        lp(a.user).positionsActive++;
        st.totals.positions++;
        this.pushActivity({ ...base, type: "position", user: getAddress(a.user), poolId: a.poolId, tickLower: a.tickLower, tickUpper: a.tickUpper });
        break;
      }
      case "PositionRemoved": {
        const l = lp(a.user);
        l.positionsActive = Math.max(0, l.positionsActive - 1);
        this.pushActivity({ ...base, type: "unposition", user: getAddress(a.user), poolId: a.poolId });
        break;
      }
      case "SwapAccounted": {
        const pool = st.pools[lc(a.poolId)];
        if (pool) {
          pool.aqua0Swaps = (pool.aqua0Swaps || 0) + 1;
          pool.lpFees0 = (BigInt(pool.lpFees0 || 0) + a.fees0).toString();
          pool.lpFees1 = (BigInt(pool.lpFees1 || 0) + a.fees1).toString();
        }
        const h = st.hooks[lc(a.hook)];
        if (h) h.swaps = (h.swaps || 0) + 1;
        st.totals.aqua0Swaps++;
        this.pushActivity({ ...base, type: "jit", poolId: a.poolId, hook: getAddress(a.hook), net0: str(a.net0), net1: str(a.net1) });
        break;
      }
    }
  }

  async handleInitialize(log) {
    const ev = decode(poolManagerAbi, log);
    if (!ev) return;
    const a = ev.args;
    if (a.hooks === zeroAddress) return;
    const h = await this.ensureHook(a.hooks);
    if (!h.isAqua0) return;
    const [t0, t1] = await Promise.all([this.ensureToken(a.currency0), this.ensureToken(a.currency1)]);
    const id = lc(a.id);
    if (this.state.pools[id]) return;
    this.state.pools[id] = {
      poolId: a.id,
      currency0: t0.address,
      currency1: t1.address,
      fee: a.fee,
      tickSpacing: a.tickSpacing,
      hooks: h.address,
      createdBlock: Number(log.blockNumber),
      createdTx: log.transactionHash,
      tick: a.tick,
      sqrtPriceX96: str(a.sqrtPriceX96),
      swaps: 0,
      aqua0Swaps: 0,
      volume0: "0",
      volume1: "0",
      ranges: [],
    };
    if (!h.pools.includes(a.id)) h.pools.push(a.id);
    this.pushActivity({ block: Number(log.blockNumber), tx: log.transactionHash, type: "pool", poolId: a.id, hook: h.address });
  }

  handleSwap(log) {
    const ev = decode(poolManagerAbi, log);
    if (!ev) return;
    const pool = this.state.pools[lc(ev.args.id)];
    if (!pool) return;
    const abs = (x) => (x < 0n ? -x : x);
    pool.swaps++;
    pool.volume0 = (BigInt(pool.volume0) + abs(ev.args.amount0)).toString();
    pool.volume1 = (BigInt(pool.volume1) + abs(ev.args.amount1)).toString();
    pool.tick = ev.args.tick;
    pool.sqrtPriceX96 = str(ev.args.sqrtPriceX96);
    this.state.totals.swaps++;
    this.pushActivity({
      block: Number(log.blockNumber),
      tx: log.transactionHash,
      type: "swap",
      poolId: ev.args.id,
      sender: getAddress(ev.args.sender),
      amount0: str(ev.args.amount0),
      amount1: str(ev.args.amount1),
    });
  }

  handleTokenCreated(log) {
    const ev = decode(factoryAbi, log);
    if (!ev) return;
    const a = ev.args;
    this.state.tokens[lc(a.token)] = {
      address: getAddress(a.token),
      name: a.name,
      symbol: a.symbol,
      decimals: a.decimals,
      factory: true,
      creator: getAddress(a.creator),
      faucetAmount: str(a.faucetAmount),
      createdBlock: Number(log.blockNumber),
    };
    this.pushActivity({ block: Number(log.blockNumber), tx: log.transactionHash, type: "token", token: getAddress(a.token), symbol: a.symbol, creator: getAddress(a.creator) });
  }

  async indexRange(fromBlock, toBlock) {
    const [slpLogs, initLogs, factoryLogs] = await Promise.all([
      client.getLogs({ address: C.sharedLiquidityPool, fromBlock, toBlock }),
      client.getLogs({ address: C.poolManager, event: initEvent, fromBlock, toBlock }),
      client.getLogs({ address: C.tokenFactory, event: tokenCreatedEvent, fromBlock, toBlock }),
    ]);
    for (const log of [...initLogs].sort(byOrder)) await this.handleInitialize(log);

    const poolIds = Object.values(this.state.pools).map((p) => p.poolId);
    const swapLogs = poolIds.length
      ? await client.getLogs({ address: C.poolManager, event: swapEvent, args: { id: poolIds }, fromBlock, toBlock })
      : [];

    const tagged = [
      ...slpLogs.map((l) => [l, "slp"]),
      ...factoryLogs.map((l) => [l, "factory"]),
      ...swapLogs.map((l) => [l, "swap"]),
    ].sort((a, b) => byOrder(a[0], b[0]));
    for (const [l, k] of tagged) {
      if (k === "slp") await this.handleSlp(l);
      else if (k === "factory") this.handleTokenCreated(l);
      else this.handleSwap(l);
    }
  }

  async refreshLive() {
    const pools = Object.values(this.state.pools);
    if (pools.length) {
      const res = await client.multicall({
        allowFailure: true,
        contracts: pools.flatMap((p) => [
          { address: C.aqua0Lens, abi: lensAbi, functionName: "getPoolState", args: [p.poolId] },
          { address: C.sharedLiquidityPool, abi: slpAbi, functionName: "getPoolRanges", args: [p.poolId] },
        ]),
      });
      pools.forEach((p, i) => {
        const [st, rg] = [res[2 * i], res[2 * i + 1]];
        if (st.status === "success") {
          p.sqrtPriceX96 = st.result.sqrtPriceX96.toString();
          p.tick = st.result.tick;
          p.lpFee = st.result.lpFee;
          p.v4Liquidity = st.result.liquidity.toString();
        }
        if (rg.status === "success") {
          p.ranges = rg.result
            .filter((r) => r.totalLiquidity > 0n)
            .map((r) => ({ tickLower: r.tickLower, tickUpper: r.tickUpper, liquidity: r.totalLiquidity.toString() }));
        }
      });
    }
    const tokens = Object.values(this.state.tokens);
    if (tokens.length) {
      const res = await client.multicall({
        allowFailure: true,
        contracts: tokens.flatMap((t) => [
          { address: C.sharedLiquidityPool, abi: slpAbi, functionName: "totalHoldings", args: [t.address] },
          { address: C.sharedLiquidityPool, abi: slpAbi, functionName: "totalLiabilities", args: [t.address] },
          { address: C.sharedLiquidityPool, abi: slpAbi, functionName: "claimBalance", args: [t.address] },
        ]),
      });
      const out = {};
      tokens.forEach((t, i) => {
        const [h, l, c] = [res[3 * i], res[3 * i + 1], res[3 * i + 2]];
        if (h.status !== "success" || (h.result === 0n && l.result === 0n)) return;
        out[lc(t.address)] = { holdings: h.result.toString(), liabilities: l.result.toString(), claims: c.result.toString() };
      });
      this.state.slp.tokens = out;
    }
    this.state.slp.paused = await tryRead(C.sharedLiquidityPool, slpAbi, "paused");
  }

  async sync() {
    if (this.status.syncing) return;
    this.status.syncing = true;
    this.emit();
    try {
      const head = await client.getBlockNumber();
      this.status.headBlock = Number(head);
      const target = head - CONFIRMATIONS;
      let from = BigInt(this.state.lastBlock) + 1n;
      while (from <= target) {
        const to = from + CHUNK - 1n < target ? from + CHUNK - 1n : target;
        await this.indexRange(from, to);
        this.state.lastBlock = to.toString();
        from = to + 1n;
        this.persist();
        this.emit();
      }
      if (Date.now() - this.lastLive > LIVE_EVERY_MS) {
        await this.refreshLive();
        this.lastLive = Date.now();
      }
      this.status.error = null;
      this.persist();
    } catch (e) {
      this.status.error = e.shortMessage || e.message;
      console.error("indexer:", e);
    } finally {
      this.status.syncing = false;
      this.emit();
    }
  }

  /** Force a live refresh soon (after the user sends a transaction) */
  poke() {
    this.lastLive = 0;
    setTimeout(() => this.sync(), 2500);
  }
}

export const indexer = new Indexer();
