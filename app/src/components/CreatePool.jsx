import { useState } from "react";
import { isAddress, getAddress } from "viem";
import { C } from "../lib/config.js";
import { poolManagerAbi, DYNAMIC_FEE_FLAG } from "../lib/abis.js";
import { write } from "../lib/wallet.js";
import { priceToSqrtPriceX96, fmtNum, short } from "../lib/format.js";
import { Card, Field, TxButton, Badge } from "./ui.jsx";

const FEES = [
  { fee: 500, spacing: 10, label: "0.05%" },
  { fee: 3000, spacing: 60, label: "0.30%" },
  { fee: 10000, spacing: 200, label: "1.00%" },
  { fee: DYNAMIC_FEE_FLAG, spacing: 60, label: "Dynamic (hook sets fee)" },
];

export default function CreatePool({ data, wallet, go }) {
  const { account, connect } = wallet;
  const tokens = Object.values(data.tokens).filter((t) => !t.native).sort((a, b) => a.symbol.localeCompare(b.symbol));
  const hooks = Object.values(data.hooks).filter((h) => h.connected);
  const [a, setA] = useState(tokens.find((t) => t.symbol === "mWETH")?.address || tokens[0]?.address || "");
  const [b, setB] = useState(tokens.find((t) => t.symbol === "mUSDC")?.address || tokens[1]?.address || "");
  const [customA, setCustomA] = useState("");
  const [customB, setCustomB] = useState("");
  const [hook, setHook] = useState(hooks[0]?.address || "");
  const [feeIdx, setFeeIdx] = useState(1);
  const [price, setPrice] = useState("3000");
  const [created, setCreated] = useState(null);

  const addrA = a === "custom" ? customA : a;
  const addrB = b === "custom" ? customB : b;
  const tA = data.tokens[addrA?.toLowerCase()];
  const tB = data.tokens[addrB?.toLowerCase()];
  const valid = isAddress(addrA || "") && isAddress(addrB || "") && addrA.toLowerCase() !== addrB.toLowerCase() && isAddress(hook || "");
  const px = Number(price);

  // Sort into currency0 < currency1 and express the price as token1 per token0.
  let key = null;
  let sqrtPriceX96 = null;
  if (valid && tA && tB && px > 0) {
    const aFirst = addrA.toLowerCase() < addrB.toLowerCase();
    const [t0, t1] = aFirst ? [tA, tB] : [tB, tA];
    const p01 = aFirst ? px : 1 / px;
    key = {
      currency0: getAddress(t0.address),
      currency1: getAddress(t1.address),
      fee: FEES[feeIdx].fee,
      tickSpacing: FEES[feeIdx].spacing,
      hooks: getAddress(hook),
    };
    sqrtPriceX96 = priceToSqrtPriceX96(p01, t0.decimals, t1.decimals);
  }
  const existing = key && Object.values(data.pools).find(
    (p) =>
      p.currency0 === key.currency0 && p.currency1 === key.currency1 && Number(p.fee) === key.fee &&
      Number(p.tickSpacing) === key.tickSpacing && p.hooks.toLowerCase() === key.hooks.toLowerCase()
  );

  return (
    <div className="stack narrow">
      <Card
        title="Create a pool"
        subtitle="Initialize a Uniswap v4 pool on any Aqua0 hook. It appears in Explore within a few seconds."
      >
        <div className="form">
          <div className="grid-form">
            <Field label="Token A">
              <select value={a} onChange={(e) => setA(e.target.value)}>
                {tokens.map((t) => (
                  <option key={t.address} value={t.address}>
                    {t.symbol} · {short(t.address)}
                  </option>
                ))}
                <option value="custom">Other address…</option>
              </select>
              {a === "custom" && <input placeholder="0x…" value={customA} onChange={(e) => setCustomA(e.target.value.trim())} />}
            </Field>
            <Field label="Token B">
              <select value={b} onChange={(e) => setB(e.target.value)}>
                {tokens.map((t) => (
                  <option key={t.address} value={t.address}>
                    {t.symbol} · {short(t.address)}
                  </option>
                ))}
                <option value="custom">Other address…</option>
              </select>
              {b === "custom" && <input placeholder="0x…" value={customB} onChange={(e) => setCustomB(e.target.value.trim())} />}
            </Field>
          </div>
          {(a === "custom" || b === "custom") && (!tA || !tB) && (
            <p className="muted tiny">
              Custom tokens must already be known to the explorer (created via the factory or used in a pool). Use the
              token factory to make one.
            </p>
          )}
          <Field label="Hook" hint="Only hooks connected to this residency's SLP are listed. Your own hook shows up here once deployed.">
            <select value={hook} onChange={(e) => setHook(e.target.value)}>
              {hooks.map((h) => (
                <option key={h.address} value={h.address}>
                  {h.name} · {short(h.address)}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Fee tier">
            <div className="seg">
              {FEES.map((f, i) => (
                <button key={f.fee} className={feeIdx === i ? "seg-btn active" : "seg-btn"} onClick={() => setFeeIdx(i)}>
                  {f.label}
                </button>
              ))}
            </div>
            <span className="field-hint">tick spacing {FEES[feeIdx].spacing}</span>
          </Field>
          <Field label={`Starting price: 1 ${tA?.symbol || "A"} = ? ${tB?.symbol || "B"}`}>
            <input value={price} onChange={(e) => setPrice(e.target.value)} inputMode="decimal" />
          </Field>
          {existing && (
            <p>
              <Badge tone="warn">exists</Badge> This exact pool is already initialized.{" "}
              <button className="link-btn" onClick={() => go("liquidity", existing.poolId)}>
                Back it instead →
              </button>
            </p>
          )}
          <TxButton
            account={account}
            connect={connect}
            disabled={!key || !!existing}
            onRun={async () => {
              const r = await write({ account, address: C.poolManager, abi: poolManagerAbi, functionName: "initialize", args: [key, sqrtPriceX96] });
              setCreated(key);
              return r;
            }}
          >
            Create pool
          </TxButton>
          {created && (
            <p className="muted tiny">
              Pool created at {fmtNum(px)} {tB?.symbol} per {tA?.symbol}. Next: back it with liquidity.
            </p>
          )}
        </div>
      </Card>
    </div>
  );
}
