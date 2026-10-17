import { useState } from "react";
import { short, addrUrl, txUrl, errMsg } from "../lib/format.js";
import { indexer } from "../lib/indexer.js";

export function Card({ title, subtitle, actions, children, className = "" }) {
  return (
    <section className={`card ${className}`}>
      {(title || actions) && (
        <header className="card-head">
          <div>
            {title && <h2>{title}</h2>}
            {subtitle && <p className="muted">{subtitle}</p>}
          </div>
          {actions && <div className="card-actions">{actions}</div>}
        </header>
      )}
      {children}
    </section>
  );
}

export function Addr({ a, label }) {
  const [copied, setCopied] = useState(false);
  if (!a) return <span className="muted">–</span>;
  return (
    <span className="addr">
      <a href={addrUrl(a)} target="_blank" rel="noreferrer" className="mono">
        {label || short(a)}
      </a>
      <button
        className="icon-btn"
        title="Copy address"
        onClick={() => {
          navigator.clipboard?.writeText(a);
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        }}
      >
        {copied ? "✓" : "⧉"}
      </button>
    </span>
  );
}

export function TxLink({ hash }) {
  return (
    <a href={txUrl(hash)} target="_blank" rel="noreferrer" className="mono">
      {short(hash)}
    </a>
  );
}

export function Badge({ tone = "neutral", children, title }) {
  return (
    <span className={`badge badge-${tone}`} title={title}>
      {children}
    </span>
  );
}

export function Stat({ label, value, hint }) {
  return (
    <div className="stat">
      <div className="stat-value">{value}</div>
      <div className="stat-label">{label}</div>
      {hint && <div className="stat-hint">{hint}</div>}
    </div>
  );
}

export function Field({ label, hint, children }) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      {children}
      {hint && <span className="field-hint">{hint}</span>}
    </label>
  );
}

export function Empty({ children }) {
  return <div className="empty">{children}</div>;
}

/** Button that runs an async action and shows its progress / error inline. */
export function TxButton({ onRun, children, disabled, kind = "primary", account, connect }) {
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState(null);
  const [error, setError] = useState(null);

  if (account === null && connect) {
    return (
      <button className="btn btn-primary" onClick={() => connect().catch((e) => setError(errMsg(e)))}>
        Connect wallet
      </button>
    );
  }

  return (
    <div className="txbtn">
      <button
        className={`btn btn-${kind}`}
        disabled={disabled || busy}
        onClick={async () => {
          setBusy(true);
          setError(null);
          setStatus("Confirm in your wallet…");
          try {
            const r = await onRun(setStatus);
            setStatus(r?.transactionHash ? <>Done · <TxLink hash={r.transactionHash} /></> : "Done");
            indexer.poke();
          } catch (e) {
            setStatus(null);
            setError(errMsg(e));
          } finally {
            setBusy(false);
          }
        }}
      >
        {busy ? "Working…" : children}
      </button>
      {status && <span className="tx-status">{status}</span>}
      {error && <span className="tx-error">{error}</span>}
    </div>
  );
}

export function TokenSelect({ tokens, value, onChange, allowEmpty }) {
  return (
    <select value={value || ""} onChange={(e) => onChange(e.target.value)}>
      {allowEmpty && <option value="">Select token</option>}
      {tokens.map((t) => (
        <option key={t.address} value={t.address}>
          {t.symbol} · {short(t.address)}
        </option>
      ))}
    </select>
  );
}
