import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { indexer } from "./lib/indexer.js";
import { useWallet } from "./lib/wallet.js";
import { short } from "./lib/format.js";
import { REPO_URL } from "./lib/config.js";
import Explore from "./components/Explore.jsx";
import Liquidity from "./components/Liquidity.jsx";
import Swap from "./components/Swap.jsx";
import CreatePool from "./components/CreatePool.jsx";
import Tokens from "./components/Tokens.jsx";
import Build from "./components/Build.jsx";

const TABS = [
  { id: "explore", label: "Explore" },
  { id: "liquidity", label: "Provide liquidity" },
  { id: "swap", label: "Swap" },
  { id: "pool", label: "Create pool" },
  { id: "tokens", label: "Tokens & faucet" },
  { id: "build", label: "Build a hook" },
];

function useIndexer() {
  return useSyncExternalStore(
    (fn) => indexer.subscribe(fn),
    () => indexer.snapshot,
    () => indexer.snapshot
  );
}

function useHashRoute() {
  const read = () => {
    const [tab, ...rest] = window.location.hash.replace(/^#\/?/, "").split("/");
    return { tab: TABS.some((t) => t.id === tab) ? tab : "explore", arg: rest.join("/") || null };
  };
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const on = () => setRoute(read());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  const go = (tab, arg) => {
    window.location.hash = `/${tab}${arg ? `/${arg}` : ""}`;
    window.scrollTo({ top: 0 });
  };
  return [route, go];
}

export default function App() {
  useEffect(() => indexer.start(), []);
  const data = useIndexer();
  const wallet = useWallet();
  const [route, go] = useHashRoute();
  const [walletErr, setWalletErr] = useState(null);

  const ctx = useMemo(() => ({ data, wallet, go, arg: route.arg }), [data, wallet, route.arg]);
  if (!data) return null;
  const status = data.status;

  return (
    <div className="shell">
      <header className="topbar">
        <a className="brand" href="#/explore">
          <img src="/aqua0.svg" alt="" width="28" height="28" />
          <span>
            Aqua0 <em>Base Hook</em>
          </span>
          <span className="brand-tag">Edge City residency</span>
        </a>
        <nav className="tabs" aria-label="Sections">
          {TABS.map((t) => (
            <a key={t.id} href={`#/${t.id}`} className={route.tab === t.id ? "tab active" : "tab"}>
              {t.label}
            </a>
          ))}
        </nav>
        <div className="wallet">
          {wallet.account ? (
            <span className={wallet.wrongChain ? "chip chip-warn" : "chip"}>
              {wallet.wrongChain ? "Wrong network · " : "Base Sepolia · "}
              <span className="mono">{short(wallet.account)}</span>
            </span>
          ) : (
            <button className="btn btn-primary" onClick={() => wallet.connect().catch((e) => setWalletErr(e.message))}>
              Connect wallet
            </button>
          )}
        </div>
      </header>
      {walletErr && <div className="banner banner-warn">{walletErr}</div>}

      <div className="disclaimer">
        <strong>Residency sandbox.</strong> Unaudited · Uniswap v4 only · single-chain, no cross-chain filler · Base
        Sepolia testnet tokens only. The final Aqua0 protocol will change; the Uniswap v4 hook interface will stay
        close to this. Aqua (1inch) support is coming.
      </div>

      <main>
        {route.tab === "explore" && <Explore {...ctx} />}
        {route.tab === "liquidity" && <Liquidity {...ctx} />}
        {route.tab === "swap" && <Swap {...ctx} />}
        {route.tab === "pool" && <CreatePool {...ctx} />}
        {route.tab === "tokens" && <Tokens {...ctx} />}
        {route.tab === "build" && <Build {...ctx} />}
      </main>

      <footer className="footer">
        <span>
          Indexed to block <span className="mono">{data.lastBlock}</span>
          {status.headBlock ? ` of ${status.headBlock}` : ""} {status.syncing ? "· syncing…" : ""}
          {status.error ? <span className="tx-error"> · RPC error: {status.error}</span> : null}
        </span>
        <span>
          Indexed in your browser, no backend ·{" "}
          <button className="link-btn" onClick={() => indexer.reset()}>
            re-index
          </button>{" "}
          ·{" "}
          <a href={REPO_URL} target="_blank" rel="noreferrer">
            GitHub
          </a>
        </span>
      </footer>
    </div>
  );
}
