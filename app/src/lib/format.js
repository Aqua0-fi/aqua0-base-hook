import { formatUnits, parseUnits } from "viem";
import { EXPLORER } from "./config.js";

export const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
export const txUrl = (h) => `${EXPLORER}/tx/${h}`;
export const addrUrl = (a) => `${EXPLORER}/address/${a}`;

/** Human number from raw units, trimmed to `digits` significant decimals */
export function fmt(raw, decimals = 18, digits = 4) {
  if (raw === undefined || raw === null) return "–";
  const n = Number(formatUnits(BigInt(raw), decimals));
  return fmtNum(n, digits);
}

export function fmtNum(n, digits = 4) {
  if (!Number.isFinite(n)) return "–";
  const a = Math.abs(n);
  if (a === 0) return "0";
  if (a >= 1e9) return `${(n / 1e9).toFixed(2)}B`;
  if (a >= 1e6) return `${(n / 1e6).toFixed(2)}M`;
  if (a >= 1000) return n.toLocaleString("en-US", { maximumFractionDigits: 2 });
  if (a >= 1) return n.toLocaleString("en-US", { maximumFractionDigits: digits });
  return n.toPrecision(Math.min(digits, 6)).replace(/0+$/, "").replace(/\.$/, "");
}

export function parseAmount(text, decimals) {
  const t = (text || "").trim().replace(/,/g, "");
  if (!t || Number(t) <= 0 || Number.isNaN(Number(t))) return null;
  try {
    return parseUnits(t, decimals);
  } catch {
    return null;
  }
}

/** token1 per token0 (human units) at a tick */
export function tickToPrice(tick, dec0, dec1) {
  return Math.pow(1.0001, Number(tick)) * Math.pow(10, dec0 - dec1);
}

export function priceToTick(price, dec0, dec1) {
  return Math.round(Math.log(price / Math.pow(10, dec0 - dec1)) / Math.log(1.0001));
}

/** sqrtPriceX96 for "1 token0 = price token1" (human units) */
export function priceToSqrtPriceX96(price, dec0, dec1) {
  const raw = price * Math.pow(10, dec1 - dec0);
  const sqrt = Math.sqrt(raw);
  // split to keep precision: sqrt * 2^96 = (sqrt * 2^48) * 2^48
  const hi = BigInt(Math.floor(sqrt * 2 ** 48));
  return hi * 2n ** 48n;
}

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;

export function rangeAround(tick, spacing, pct) {
  const s = Number(spacing);
  if (pct === "full") {
    return [Math.ceil(MIN_TICK / s) * s, Math.floor(MAX_TICK / s) * s];
  }
  const d = Math.max(s, Math.round(Math.log(1 + pct / 100) / Math.log(1.0001)));
  let lower = Math.floor((Number(tick) - d) / s) * s;
  let upper = Math.ceil((Number(tick) + d) / s) * s;
  if (upper === lower) upper += s;
  lower = Math.max(lower, Math.ceil(MIN_TICK / s) * s);
  upper = Math.min(upper, Math.floor(MAX_TICK / s) * s);
  return [lower, upper];
}

export function feeLabel(fee) {
  if (Number(fee) === 0x800000) return "dynamic";
  return `${(Number(fee) / 10000).toFixed(2)}%`;
}

export function poolKeyOf(p) {
  return {
    currency0: p.currency0,
    currency1: p.currency1,
    fee: Number(p.fee),
    tickSpacing: Number(p.tickSpacing),
    hooks: p.hooks,
  };
}

export function ago(block, head) {
  if (!head || !block) return "";
  const secs = (head - block) * 2;
  if (secs < 90) return `${secs}s ago`;
  if (secs < 5400) return `${Math.round(secs / 60)}m ago`;
  if (secs < 172800) return `${Math.round(secs / 3600)}h ago`;
  return `${Math.round(secs / 86400)}d ago`;
}

export function errMsg(e) {
  const m = e?.shortMessage || e?.details || e?.message || String(e);
  return m.split("\n")[0].slice(0, 220);
}
