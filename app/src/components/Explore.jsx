import { Card, Addr, Badge, Stat, Empty, TxLink } from "./ui.jsx";
import { fmt, fmtNum, tickToPrice, feeLabel, ago, short } from "../lib/format.js";
import { REPO_URL } from "../lib/config.js";

export function tokenOf(data, addr) {
  return data.tokens[addr?.toLowerCase()] || { symbol: short(addr), decimals: 18, address: addr };
}

export function poolLabel(data, p) {
  const t0 = tokenOf(data, p.currency0);
  const t1 = tokenOf(data, p.currency1);
  return `${t0.symbol}/${t1.symbol}`;
}

export function poolPrice(data, p) {
  const t0 = tokenOf(data, p.currency0);
  const t1 = tokenOf(data, p.currency1);
  if (p.tick === undefined || p.tick === null) return null;
  return tickToPrice(p.tick, t0.decimals, t1.decimals);
}

/** "1 mWETH = 3,000 mUSDC", flipping so the bigger number shows */
export function priceText(data, p) {
  const t0 = tokenOf(data, p.currency0);
  const t1 = tokenOf(data, p.currency1);
  const px = poolPrice(data, p);
  if (px === null) return "–";
  return px >= 1 ? `1 ${t0.symbol} = ${fmtNum(px, 5)} ${t1.symbol}` : `1 ${t1.symbol} = ${fmtNum(1 / px, 5)} ${t0.symbol}`;
}

function HookStatus({ h }) {
  if (h.connected) return <Badge tone="good" title="Extends Aqua0BaseHook and uses this residency's SLP">Aqua0 · this SLP</Badge>;
  if (h.isAqua0) return <Badge tone="warn" title="Aqua0 hook pointing at a different SharedLiquidityPool">Aqua0 · other SLP</Badge>;
  return <Badge tone="bad" title="Registered but does not pass the Aqua0 ERC165 check">not verified</Badge>;
}

export default function Explore({ data, go }) {
  const hooks = Object.values(data.hooks).sort((a, b) => (b.registeredBlock || 0) - (a.registeredBlock || 0));
  const pools = Object.values(data.pools).sort((a, b) => b.createdBlock - a.createdBlock);
  const head = data.status.headBlock;
  const reserves = Object.entries(data.slp?.tokens || {});

  return (
    <div className="stack">
      <section className="hero">
        <div>
          <h1>One deposit, every pool.</h1>
          <p className="lede">
            Aqua0's Shared Liquidity Pool (SLP) lends the same LP capital, just in time, to every Uniswap v4 pool whose
            hook extends <code>Aqua0BaseHook</code>. Deploy a hook and it shows up here on its own. Nothing to submit,
            no backend.
          </p>
          <div className="hero-actions">
            <button className="btn btn-primary" onClick={() => go("build")}>
              Build a hook
            </button>
            <button className="btn" onClick={() => go("liquidity")}>
              Provide liquidity
            </button>
            <button className="btn" onClick={() => go("tokens")}>
              Get test tokens
            </button>
            <a className="btn btn-ghost" href={REPO_URL} target="_blank" rel="noreferrer">
              GitHub ↗
            </a>
          </div>
        </div>
        <div className="stats">
          <Stat label="Aqua0 hooks" value={hooks.filter((h) => h.isAqua0).length} />
          <Stat label="Aqua0 pools" value={pools.length} />
          <Stat label="Swaps on shared liquidity" value={data.totals.aqua0Swaps} />
          <Stat label="LPs" value={Object.keys(data.lps).length} />
        </div>
      </section>

      <Card
        title="Hooks"
        subtitle="Every contract extending Aqua0BaseHook registers itself with the SLP when it is deployed."
      >
        {hooks.length === 0 ? (
          <Empty>No hooks yet. Indexing…</Empty>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Hook</th>
                  <th>Address</th>
                  <th>Deployed by</th>
                  <th className="num">Pools</th>
                  <th className="num">JIT swaps</th>
                  <th>Status</th>
                  <th>Seen</th>
                </tr>
              </thead>
              <tbody>
                {hooks.map((h) => (
                  <tr key={h.address}>
                    <td className="strong">
                      {h.name}
                      {h.official && <Badge tone="info">by Aqua0</Badge>}
                    </td>
                    <td>
                      <Addr a={h.address} />
                    </td>
                    <td>{h.deployer ? <Addr a={h.deployer} /> : <span className="muted">via pool</span>}</td>
                    <td className="num">{h.pools.length}</td>
                    <td className="num">{h.swaps || 0}</td>
                    <td>
                      <HookStatus h={h} />
                    </td>
                    <td className="muted">{h.registeredTx ? <TxLink hash={h.registeredTx} /> : ago(h.registeredBlock, head)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <Card
        title="Pools"
        subtitle="Any Uniswap v4 pool whose hook passes the Aqua0 ERC165 check, picked up from PoolManager Initialize events."
        actions={
          <button className="btn btn-small" onClick={() => go("pool")}>
            + Create pool
          </button>
        }
      >
        {pools.length === 0 ? (
          <Empty>No Aqua0 pools yet.</Empty>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Pool</th>
                  <th>Fee</th>
                  <th>Hook</th>
                  <th>Price</th>
                  <th className="num">Shared ranges</th>
                  <th className="num">Swaps</th>
                  <th className="num">Volume</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {pools.map((p) => {
                  const t0 = tokenOf(data, p.currency0);
                  const t1 = tokenOf(data, p.currency1);
                  const h = data.hooks[p.hooks.toLowerCase()];
                  return (
                    <tr key={p.poolId}>
                      <td className="strong">
                        {t0.symbol}/{t1.symbol}
                        <div className="mono tiny muted">{short(p.poolId)}</div>
                      </td>
                      <td>{feeLabel(p.fee)}</td>
                      <td>
                        {h?.name || "–"}
                        <div className="tiny">
                          <Addr a={p.hooks} />
                        </div>
                      </td>
                      <td>{priceText(data, p)}</td>
                      <td className="num">{p.ranges?.length ?? "–"}</td>
                      <td className="num">{p.swaps}</td>
                      <td className="num">
                        {fmt(p.volume0, t0.decimals, 3)} {t0.symbol}
                        <div className="tiny muted">
                          {fmt(p.volume1, t1.decimals, 3)} {t1.symbol}
                        </div>
                      </td>
                      <td className="row-actions">
                        <button className="btn btn-small" onClick={() => go("swap", p.poolId)}>
                          Swap
                        </button>
                        <button className="btn btn-small" onClick={() => go("liquidity", p.poolId)}>
                          Back it
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <div className="grid-2">
        <Card title="SLP reserves" subtitle="Tokens held vs. owed to LPs. Holdings ≥ owed at all times.">
          {reserves.length === 0 ? (
            <Empty>Loading…</Empty>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Token</th>
                  <th className="num">Held</th>
                  <th className="num">Owed to LPs</th>
                  <th className="num">As v4 claims</th>
                </tr>
              </thead>
              <tbody>
                {reserves.map(([addr, r]) => {
                  const t = tokenOf(data, addr);
                  return (
                    <tr key={addr}>
                      <td className="strong">{t.symbol}</td>
                      <td className="num">{fmt(r.holdings, t.decimals)}</td>
                      <td className="num">{fmt(r.liabilities, t.decimals)}</td>
                      <td className="num muted">{fmt(r.claims, t.decimals)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </Card>

        <Card title="Activity" subtitle="Latest on-chain events">
          <ul className="feed">
            {data.activity.slice(0, 14).map((a, i) => (
              <li key={`${a.tx}-${i}`}>
                <ActivityLine a={a} data={data} />
                <span className="muted tiny">
                  {ago(a.block, head)} · <TxLink hash={a.tx} />
                </span>
              </li>
            ))}
            {data.activity.length === 0 && <Empty>Nothing yet.</Empty>}
          </ul>
        </Card>
      </div>
    </div>
  );
}

function Who({ a, data }) {
  const h = data.hooks[a?.toLowerCase()];
  return h ? <span title={a}>{h.name.split(" (")[0]}</span> : <span className="mono">{short(a)}</span>;
}

function ActivityLine({ a, data }) {
  const pool = a.poolId ? data.pools[a.poolId.toLowerCase()] : null;
  const pl = pool ? poolLabel(data, pool) : "pool";
  const t = a.token ? tokenOf(data, a.token) : null;
  switch (a.type) {
    case "hook":
      return (
        <span>
          <Badge tone="good">new hook</Badge> {a.name} by <span className="mono">{short(a.deployer)}</span>
        </span>
      );
    case "pool":
      return (
        <span>
          <Badge tone="info">new pool</Badge> {pl} on {data.hooks[a.hook?.toLowerCase()]?.name || short(a.hook)}
        </span>
      );
    case "deposit":
      return (
        <span>
          <Who a={a.user} data={data} /> deposited {fmt(a.amount, t.decimals)} {t.symbol}
        </span>
      );
    case "withdraw":
      return (
        <span>
          <Who a={a.user} data={data} /> withdrew {fmt(a.amount, t.decimals)} {t.symbol}
        </span>
      );
    case "claim":
      return (
        <span>
          <Who a={a.user} data={data} /> claimed {fmt(a.amount, t.decimals)} {t.symbol} in fees
        </span>
      );
    case "position":
      return (
        <span>
          <Who a={a.user} data={data} /> backed {pl} [{a.tickLower}, {a.tickUpper}]
        </span>
      );
    case "unposition":
      return (
        <span>
          <Who a={a.user} data={data} /> stopped backing {pl}
        </span>
      );
    case "jit":
      return (
        <span>
          <Badge tone="aqua">JIT</Badge> shared liquidity used in {pl}
        </span>
      );
    case "swap": {
      if (!pool) return <span>swap</span>;
      const t0 = tokenOf(data, pool.currency0);
      const t1 = tokenOf(data, pool.currency1);
      const in0 = BigInt(a.amount0) < 0n;
      const amtIn = in0 ? -BigInt(a.amount0) : -BigInt(a.amount1);
      const amtOut = in0 ? BigInt(a.amount1) : BigInt(a.amount0);
      return (
        <span>
          swap {fmt(amtIn, (in0 ? t0 : t1).decimals)} {(in0 ? t0 : t1).symbol} → {fmt(amtOut, (in0 ? t1 : t0).decimals)}{" "}
          {(in0 ? t1 : t0).symbol}
        </span>
      );
    }
    case "token":
      return (
        <span>
          <Badge tone="neutral">new token</Badge> {a.symbol} by <span className="mono">{short(a.creator)}</span>
        </span>
      );
    default:
      return <span>{a.type}</span>;
  }
}
