import { useEffect, useMemo, useState } from "react";
import { publicClient, C } from "../lib/config.js";
import { slpAbi, lensAbi, erc20Abi } from "../lib/abis.js";
import { write, ensureAllowance } from "../lib/wallet.js";
import { fmt, fmtNum, parseAmount, rangeAround, tickToPrice, poolKeyOf, feeLabel } from "../lib/format.js";
import { Card, Field, TxButton, TokenSelect, Empty, Badge } from "./ui.jsx";
import { tokenOf, poolLabel, priceText } from "./Explore.jsx";

const PRESETS = [
  { id: 1, label: "±1%" },
  { id: 5, label: "±5%" },
  { id: 20, label: "±20%" },
  { id: 60, label: "±60%" },
  { id: "full", label: "Full range" },
];

export function useBalances(account, tokens, tick) {
  const [rows, setRows] = useState({});
  useEffect(() => {
    if (!account || tokens.length === 0) return;
    let dead = false;
    publicClient
      .multicall({
        allowFailure: true,
        contracts: tokens.flatMap((t) => [
          { address: t.address, abi: erc20Abi, functionName: "balanceOf", args: [account] },
          { address: C.sharedLiquidityPool, abi: slpAbi, functionName: "freeBalance", args: [account, t.address] },
          { address: C.sharedLiquidityPool, abi: slpAbi, functionName: "earnedFees", args: [account, t.address] },
        ]),
      })
      .then((res) => {
        if (dead) return;
        const out = {};
        tokens.forEach((t, i) => {
          const v = (k) => (res[3 * i + k].status === "success" ? res[3 * i + k].result : 0n);
          out[t.address.toLowerCase()] = { wallet: v(0), free: v(1), fees: v(2) };
        });
        setRows(out);
      });
    return () => {
      dead = true;
    };
  }, [account, tokens.map((t) => t.address).join(), tick]);
  return rows;
}

export default function Liquidity({ data, wallet, arg }) {
  const { account, connect } = wallet;
  const tokens = useMemo(
    () => Object.values(data.tokens).filter((t) => !t.native).sort((a, b) => a.symbol.localeCompare(b.symbol)),
    [data.tokens]
  );
  const pools = Object.values(data.pools).sort((a, b) => a.createdBlock - b.createdBlock);
  const bal = useBalances(account, tokens, data.lastBlock + data.activity.length);

  return (
    <div className="stack">
      <Card
        title="How the Shared Liquidity Pool works"
        subtitle="Three steps. Your tokens stay in the SLP the whole time."
      >
        <ol className="steps">
          <li>
            <strong>Deposit</strong> tokens into the SLP. They become your <em>free balance</em> and can be withdrawn any
            time.
          </li>
          <li>
            <strong>Back pools</strong>: pick any Aqua0 pool and a price range. Nothing moves; the same free balance can
            back many pools at once. If your balance can't cover a range at swap time, it's scaled down automatically.
          </li>
          <li>
            <strong>Earn</strong>: each swap borrows your liquidity for that one transaction, then hands it back with
            your share of the trade and the LP fee. Fees are claimable separately.
          </li>
        </ol>
      </Card>

      <div className="grid-2">
        <BalancesCard tokens={tokens} bal={bal} account={account} connect={connect} />
        <MoveFundsCard tokens={tokens} bal={bal} account={account} connect={connect} />
      </div>

      <BackPoolCard data={data} pools={pools} bal={bal} account={account} connect={connect} initial={arg} />
      <PositionsCard data={data} account={account} />
    </div>
  );
}

function BalancesCard({ tokens, bal, account }) {
  return (
    <Card title="Your balances" subtitle={account ? null : "Connect a wallet to see balances."}>
      <table>
        <thead>
          <tr>
            <th>Token</th>
            <th className="num">Wallet</th>
            <th className="num">SLP free</th>
            <th className="num">Fees</th>
          </tr>
        </thead>
        <tbody>
          {tokens.map((t) => {
            const r = bal[t.address.toLowerCase()];
            return (
              <tr key={t.address}>
                <td className="strong">{t.symbol}</td>
                <td className="num">{r ? fmt(r.wallet, t.decimals) : "–"}</td>
                <td className="num">{r ? fmt(r.free, t.decimals) : "–"}</td>
                <td className="num">{r ? fmt(r.fees, t.decimals) : "–"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </Card>
  );
}

function MoveFundsCard({ tokens, bal, account, connect }) {
  const [token, setToken] = useState("");
  const [amount, setAmount] = useState("");
  const t = tokens.find((x) => x.address === token) || tokens[0];
  const r = t ? bal[t.address.toLowerCase()] : null;
  const raw = t ? parseAmount(amount, t.decimals) : null;

  return (
    <Card title="Deposit / withdraw" subtitle="Move tokens between your wallet and the SLP.">
      <div className="form">
        <Field label="Token">
          <TokenSelect tokens={tokens} value={t?.address} onChange={setToken} />
        </Field>
        <Field
          label="Amount"
          hint={
            r && t ? (
              <>
                wallet{" "}
                <button className="link-btn" onClick={() => setAmount(fmtRaw(r.wallet, t.decimals))}>
                  {fmt(r.wallet, t.decimals)}
                </button>{" "}
                · SLP{" "}
                <button className="link-btn" onClick={() => setAmount(fmtRaw(r.free, t.decimals))}>
                  {fmt(r.free, t.decimals)}
                </button>
              </>
            ) : null
          }
        >
          <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.0" inputMode="decimal" />
        </Field>
        <div className="btn-row">
          <TxButton
            account={account}
            connect={connect}
            disabled={!raw}
            onRun={async (status) => {
              await ensureAllowance({ account, token: t.address, spender: C.sharedLiquidityPool, amount: raw, onStatus: status });
              status("Deposit in your wallet…");
              return write({ account, address: C.sharedLiquidityPool, abi: slpAbi, functionName: "deposit", args: [t.address, raw, account] });
            }}
          >
            Deposit
          </TxButton>
          {account && (
            <TxButton
              kind="secondary"
              disabled={!raw}
              onRun={() =>
                write({ account, address: C.sharedLiquidityPool, abi: slpAbi, functionName: "withdraw", args: [t.address, raw, account, account] })
              }
            >
              Withdraw
            </TxButton>
          )}
          {account && r?.fees > 0n && (
            <TxButton
              kind="secondary"
              onRun={() =>
                write({ account, address: C.sharedLiquidityPool, abi: slpAbi, functionName: "claimFees", args: [t.address, account, account] })
              }
            >
              Claim {fmt(r.fees, t.decimals)} fees
            </TxButton>
          )}
        </div>
        <p className="muted tiny">Need tokens? Use the faucet in “Tokens & faucet”.</p>
      </div>
    </Card>
  );
}

function fmtRaw(raw, decimals) {
  const s = raw.toString().padStart(decimals + 1, "0");
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals).replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

function BackPoolCard({ data, pools, bal, account, connect, initial }) {
  const [poolId, setPoolId] = useState(initial || pools[0]?.poolId || "");
  const [preset, setPreset] = useState(20);
  const [a0, setA0] = useState("");
  const [a1, setA1] = useState("");
  const [preview, setPreview] = useState(null);

  useEffect(() => {
    if (initial) setPoolId(initial);
  }, [initial]);

  const p = data.pools[poolId?.toLowerCase()] || pools[0];
  const t0 = p ? tokenOf(data, p.currency0) : null;
  const t1 = p ? tokenOf(data, p.currency1) : null;
  const [tl, tu] = p && p.tick !== undefined ? rangeAround(p.tick, p.tickSpacing, preset) : [0, 0];
  const raw0 = t0 ? parseAmount(a0, t0.decimals) ?? 0n : 0n;
  const raw1 = t1 ? parseAmount(a1, t1.decimals) ?? 0n : 0n;

  useEffect(() => {
    setPreview(null);
    if (!p || (raw0 === 0n && raw1 === 0n)) return;
    const id = setTimeout(() => {
      publicClient
        .readContract({ address: C.aqua0Lens, abi: lensAbi, functionName: "liquidityForAmounts", args: [p.poolId, tl, tu, raw0, raw1] })
        .then(([liquidity, used0, used1]) => setPreview({ liquidity, used0, used1 }))
        .catch(() => setPreview(null));
    }, 300);
    return () => clearTimeout(id);
  }, [p?.poolId, tl, tu, raw0, raw1]);

  if (!p) return <Card title="Back a pool"><Empty>No pools indexed yet.</Empty></Card>;
  const free0 = bal[t0.address.toLowerCase()]?.free ?? 0n;
  const free1 = bal[t1.address.toLowerCase()]?.free ?? 0n;
  const use0 = preview ? (preview.used0 > raw0 ? raw0 : preview.used0) : 0n;
  const use1 = preview ? (preview.used1 > raw1 ? raw1 : preview.used1) : 0n;
  const short0 = use0 > free0;
  const short1 = use1 > free1;

  return (
    <Card
      title="Back a pool"
      subtitle="Allocate part of your free balance to a pool and range. Your tokens don't leave the SLP."
    >
      <div className="form grid-form">
        <Field label="Pool">
          <select value={p.poolId} onChange={(e) => setPoolId(e.target.value)}>
            {pools.map((x) => (
              <option key={x.poolId} value={x.poolId}>
                {poolLabel(data, x)} · {feeLabel(x.fee)} · {data.hooks[x.hooks.toLowerCase()]?.name || x.hooks}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Current price">
          <div className="readout">{priceText(data, p)}</div>
        </Field>
        <Field label="Range">
          <div className="seg">
            {PRESETS.map((x) => (
              <button key={x.id} className={preset === x.id ? "seg-btn active" : "seg-btn"} onClick={() => setPreset(x.id)}>
                {x.label}
              </button>
            ))}
          </div>
          <span className="field-hint">
            ticks [{tl}, {tu}] · {fmtNum(tickToPrice(tl, t0.decimals, t1.decimals), 5)} to{" "}
            {fmtNum(tickToPrice(tu, t0.decimals, t1.decimals), 5)} {t1.symbol} per {t0.symbol}
          </span>
        </Field>
        <Field label={`Max ${t0.symbol}`} hint={`SLP free: ${fmt(free0, t0.decimals)}`}>
          <input value={a0} onChange={(e) => setA0(e.target.value)} placeholder="0.0" inputMode="decimal" />
        </Field>
        <Field label={`Max ${t1.symbol}`} hint={`SLP free: ${fmt(free1, t1.decimals)}`}>
          <input value={a1} onChange={(e) => setA1(e.target.value)} placeholder="0.0" inputMode="decimal" />
        </Field>
        <Field label="Preview">
          <div className="readout">
            {preview ? (
              <>
                {fmt(use0, t0.decimals)} {t0.symbol} + {fmt(use1, t1.decimals)} {t1.symbol}
                <div className="tiny muted">liquidity {preview.liquidity.toString()}</div>
              </>
            ) : (
              <span className="muted">enter amounts</span>
            )}
          </div>
        </Field>
      </div>
      {(short0 || short1) && (
        <p className="tx-error">Deposit more first: the amounts you earmark must be in your SLP free balance.</p>
      )}
      <TxButton
        account={account}
        connect={connect}
        disabled={!preview || preview.liquidity === 0n || short0 || short1}
        onRun={() =>
          write({
            account,
            address: C.sharedLiquidityPool,
            abi: slpAbi,
            functionName: "addPosition",
            args: [poolKeyOf(p), tl, tu, preview.liquidity, use0, use1, account],
          })
        }
      >
        Back this pool
      </TxButton>
    </Card>
  );
}

function PositionsCard({ data, account }) {
  const [positions, setPositions] = useState(null);
  const tick = data.lastBlock + data.activity.length;
  useEffect(() => {
    if (!account) return;
    publicClient
      .readContract({ address: C.aqua0Lens, abi: lensAbi, functionName: "getUserPositions", args: [account] })
      .then(setPositions)
      .catch(() => setPositions([]));
  }, [account, tick]);

  const active = (positions || []).filter((x) => x.active);
  return (
    <Card title="Your positions" subtitle="Ranges you back. Removing one never moves tokens; your free balance stays.">
      {!account ? (
        <Empty>Connect a wallet.</Empty>
      ) : active.length === 0 ? (
        <Empty>No active positions.</Empty>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Pool</th>
                <th>Range</th>
                <th className="num">Worth now</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {active.map((x) => {
                const p = data.pools[x.poolId.toLowerCase()];
                if (!p) return null;
                const t0 = tokenOf(data, p.currency0);
                const t1 = tokenOf(data, p.currency1);
                const inRange = p.tick >= x.tickLower && p.tick < x.tickUpper;
                return (
                  <tr key={x.positionId}>
                    <td className="strong">
                      {poolLabel(data, p)} <span className="muted tiny">{data.hooks[p.hooks.toLowerCase()]?.name}</span>
                    </td>
                    <td>
                      {fmtNum(tickToPrice(x.tickLower, t0.decimals, t1.decimals), 5)} –{" "}
                      {fmtNum(tickToPrice(x.tickUpper, t0.decimals, t1.decimals), 5)}
                    </td>
                    <td className="num">
                      {fmt(x.amount0Now, t0.decimals)} {t0.symbol}
                      <div className="tiny muted">
                        {fmt(x.amount1Now, t1.decimals)} {t1.symbol}
                      </div>
                    </td>
                    <td>{inRange ? <Badge tone="good">in range</Badge> : <Badge tone="warn">out of range</Badge>}</td>
                    <td>
                      <TxButton
                        kind="secondary"
                        onRun={() =>
                          write({
                            account,
                            address: C.sharedLiquidityPool,
                            abi: slpAbi,
                            functionName: "removePosition",
                            args: [poolKeyOf(p), x.tickLower, x.tickUpper, account],
                          })
                        }
                      >
                        Remove
                      </TxButton>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
