import { useEffect, useState } from "react";
import { ContractFunctionRevertedError } from "viem";
import { publicClient, C } from "../lib/config.js";
import { quoteAbi, swapRouterAbi, MIN_SQRT_PRICE, MAX_SQRT_PRICE } from "../lib/abis.js";
import { write, ensureAllowance } from "../lib/wallet.js";
import { fmt, parseAmount, poolKeyOf, feeLabel, errMsg } from "../lib/format.js";
import { Card, Field, TxButton, Empty } from "./ui.jsx";
import { tokenOf, poolLabel, priceText } from "./Explore.jsx";
import { useBalances } from "./Liquidity.jsx";

async function getQuote(pool, zeroForOne, amountSpecified, account) {
  try {
    await publicClient.simulateContract({
      address: C.aqua0QuoteHelper,
      abi: quoteAbi,
      functionName: "quote",
      args: [poolKeyOf(pool), zeroForOne, amountSpecified],
      account: account || undefined,
    });
  } catch (e) {
    const revert = e.walk?.((x) => x instanceof ContractFunctionRevertedError);
    if (revert?.data?.errorName === "Quote") {
      const [amount0, amount1, slp0, slp1] = revert.data.args;
      return { amount0, amount1, slp0, slp1 };
    }
    throw e;
  }
  throw new Error("quote did not revert");
}

export default function Swap({ data, wallet, arg }) {
  const { account, connect } = wallet;
  const pools = Object.values(data.pools).sort((a, b) => a.createdBlock - b.createdBlock);
  const [poolId, setPoolId] = useState(arg || pools[0]?.poolId || "");
  const [zeroForOne, setZeroForOne] = useState(true);
  const [amount, setAmount] = useState("");
  const [q, setQ] = useState(null);
  const [qErr, setQErr] = useState(null);

  useEffect(() => {
    if (arg) setPoolId(arg);
  }, [arg]);

  const p = data.pools[poolId?.toLowerCase()] || pools[0];
  const t0 = p ? tokenOf(data, p.currency0) : null;
  const t1 = p ? tokenOf(data, p.currency1) : null;
  const tin = zeroForOne ? t0 : t1;
  const tout = zeroForOne ? t1 : t0;
  const raw = tin ? parseAmount(amount, tin.decimals) : null;
  const bal = useBalances(account, p ? [t0, t1] : [], data.lastBlock);

  useEffect(() => {
    setQ(null);
    setQErr(null);
    if (!p || !raw) return;
    const id = setTimeout(() => {
      getQuote(p, zeroForOne, -raw, account)
        .then(setQ)
        .catch((e) => setQErr(errMsg(e)));
    }, 350);
    return () => clearTimeout(id);
  }, [p?.poolId, zeroForOne, raw, account]);

  if (!p) return <Card title="Swap"><Empty>No pools indexed yet.</Empty></Card>;

  const out = q ? (zeroForOne ? q.amount1 : q.amount0) : null;
  const slpIn = q ? (zeroForOne ? q.slp0 : q.slp1) : null;
  const slpOut = q ? -(zeroForOne ? q.slp1 : q.slp0) : null;

  return (
    <div className="stack narrow">
      <Card title="Swap" subtitle="Routes through the pool's hook, so Aqua0 shared liquidity takes part in the trade.">
        <div className="form">
          <Field label="Pool">
            <select value={p.poolId} onChange={(e) => setPoolId(e.target.value)}>
              {pools.map((x) => (
                <option key={x.poolId} value={x.poolId}>
                  {poolLabel(data, x)} · {feeLabel(x.fee)} · {data.hooks[x.hooks.toLowerCase()]?.name || x.hooks}
                </option>
              ))}
            </select>
            <span className="field-hint">{priceText(data, p)}</span>
          </Field>
          <Field
            label={`You pay (${tin.symbol})`}
            hint={account ? `wallet: ${fmt(bal[tin.address.toLowerCase()]?.wallet ?? 0n, tin.decimals)}` : null}
          >
            <div className="input-row">
              <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.0" inputMode="decimal" />
              <button className="btn btn-small" onClick={() => setZeroForOne(!zeroForOne)} title="Flip direction">
                ⇅ flip
              </button>
            </div>
          </Field>
          <Field label={`You get (${tout.symbol})`}>
            <div className="readout big">{out !== null ? fmt(out, tout.decimals, 6) : "–"}</div>
          </Field>
          {q && (
            <p className="muted tiny">
              Shared liquidity took in {fmt(slpIn, tin.decimals)} {tin.symbol} and paid out {fmt(slpOut, tout.decimals)}{" "}
              {tout.symbol} of this trade.
            </p>
          )}
          {qErr && <p className="tx-error">Quote failed: {qErr}</p>}
          <TxButton
            account={account}
            connect={connect}
            disabled={!raw || !q}
            onRun={async (status) => {
              await ensureAllowance({ account, token: tin.address, spender: C.poolSwapTest, amount: raw, onStatus: status });
              status("Swap in your wallet…");
              return write({
                account,
                address: C.poolSwapTest,
                abi: swapRouterAbi,
                functionName: "swap",
                args: [
                  poolKeyOf(p),
                  { zeroForOne, amountSpecified: -raw, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n },
                  { takeClaims: false, settleUsingBurn: false },
                  "0x",
                ],
              });
            }}
          >
            Swap
          </TxButton>
          <p className="muted tiny">
            Uses Uniswap's PoolSwapTest router on Base Sepolia. Testnet only: there is no slippage limit.
          </p>
        </div>
      </Card>
    </div>
  );
}
