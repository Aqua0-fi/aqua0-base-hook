import { useState } from "react";
import { parseEventLogs } from "viem";
import { C, FAUCETS, deployments } from "../lib/config.js";
import { factoryAbi, erc20Abi } from "../lib/abis.js";
import { write, watchAsset } from "../lib/wallet.js";
import { fmt, short } from "../lib/format.js";
import { Card, Field, TxButton, Addr, Badge, Empty } from "./ui.jsx";
import { useBalances } from "./Liquidity.jsx";

export default function Tokens({ data, wallet }) {
  const { account, connect } = wallet;
  const tokens = Object.values(data.tokens)
    .filter((t) => t.factory)
    .sort((a, b) => (a.createdBlock || 0) - (b.createdBlock || 0));
  const bal = useBalances(account, tokens, data.lastBlock + data.activity.length);
  const [name, setName] = useState("");
  const [symbol, setSymbol] = useState("");
  const [decimals, setDecimals] = useState("18");
  const [faucetUnits, setFaucetUnits] = useState("10000");
  const [made, setMade] = useState(null);

  const valid = name.trim().length > 0 && name.length <= 32 && symbol.trim().length > 0 && symbol.length <= 12 && Number(decimals) >= 0 && Number(decimals) <= 18;

  return (
    <div className="stack">
      <div className="grid-2">
        <Card title="Launch a test token" subtitle="One transaction. You get 1,000,000; anyone can mint more from its built-in faucet.">
          <div className="form">
            <Field label="Name">
              <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Edge City Dollar" maxLength={32} />
            </Field>
            <div className="grid-form">
              <Field label="Symbol">
                <input value={symbol} onChange={(e) => setSymbol(e.target.value.toUpperCase())} placeholder="ECD" maxLength={12} />
              </Field>
              <Field label="Decimals">
                <input value={decimals} onChange={(e) => setDecimals(e.target.value)} inputMode="numeric" />
              </Field>
            </div>
            <Field label="Faucet amount per click" hint="Whole tokens anyone can mint per call">
              <input value={faucetUnits} onChange={(e) => setFaucetUnits(e.target.value)} inputMode="numeric" />
            </Field>
            <TxButton
              account={account}
              connect={connect}
              disabled={!valid}
              onRun={async () => {
                const r = await write({
                  account,
                  address: C.tokenFactory,
                  abi: factoryAbi,
                  functionName: "createToken",
                  args: [name.trim(), symbol.trim(), Number(decimals), BigInt(faucetUnits || "0")],
                });
                const ev = parseEventLogs({ abi: factoryAbi, logs: r.logs, eventName: "TokenCreated" })[0];
                if (ev) setMade({ address: ev.args.token, symbol: ev.args.symbol, decimals: ev.args.decimals });
                return r;
              }}
            >
              Create token
            </TxButton>
            {made && (
              <p className="muted tiny">
                {made.symbol} is live at <Addr a={made.address} />.{" "}
                <button className="link-btn" onClick={() => watchAsset(made)}>
                  Add to wallet
                </button>
              </p>
            )}
          </div>
        </Card>

        <Card title="Gas (Base Sepolia ETH)" subtitle="You need a little testnet ETH for gas. Any of these work:">
          <ul className="links">
            {FAUCETS.map((f) => (
              <li key={f.url}>
                <a href={f.url} target="_blank" rel="noreferrer">
                  {f.name} ↗
                </a>
              </li>
            ))}
          </ul>
          <p className="muted tiny">Swaps and deposits here cost well under $0.01 of testnet gas.</p>
        </Card>
      </div>

      <Card title="Faucet" subtitle="Every token made by the factory. Tap to mint to your wallet. All on-chain, no backend.">
        {tokens.length === 0 ? (
          <Empty>No tokens yet.</Empty>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Token</th>
                  <th>Address</th>
                  <th>Creator</th>
                  <th className="num">Per click</th>
                  <th className="num">Your balance</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {tokens.map((t) => (
                  <tr key={t.address}>
                    <td className="strong">
                      {t.symbol} <span className="muted tiny">{t.name}</span>
                      {t.creator?.toLowerCase() === deployments.deployer.toLowerCase() && <Badge tone="info">Aqua0</Badge>}
                    </td>
                    <td>
                      <Addr a={t.address} />
                    </td>
                    <td className="mono tiny">{short(t.creator)}</td>
                    <td className="num">{fmt(t.faucetAmount, t.decimals)}</td>
                    <td className="num">{account ? fmt(bal[t.address.toLowerCase()]?.wallet ?? 0n, t.decimals) : "–"}</td>
                    <td className="row-actions">
                      <TxButton
                        account={account}
                        connect={connect}
                        onRun={() => write({ account, address: t.address, abi: erc20Abi, functionName: "faucet" })}
                      >
                        Mint {fmt(t.faucetAmount, t.decimals)}
                      </TxButton>
                      <button className="btn btn-small btn-ghost" onClick={() => watchAsset(t)} title="Add to wallet">
                        + wallet
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
