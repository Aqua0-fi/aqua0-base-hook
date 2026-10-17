import { createPublicClient, fallback, http, getAddress } from "viem";
import { baseSepolia } from "viem/chains";
import deployments from "@deployments/base-sepolia.json";

export { deployments };

export const REPO_URL = "https://github.com/Aqua0-fi/aqua0-base-hook";
export const EXPLORER = "https://sepolia.basescan.org";
export const CHAIN = baseSepolia;

/** Browser-friendly RPCs that allow wide eth_getLogs ranges (sepolia.base.org caps at 200 blocks). */
export const RPC_URLS = [
  import.meta.env.VITE_RPC_URL,
  "https://base-sepolia-rpc.publicnode.com",
  "https://base-sepolia.gateway.tenderly.co",
].filter(Boolean);

export const publicClient = createPublicClient({
  chain: baseSepolia,
  transport: fallback(RPC_URLS.map((u) => http(u, { retryCount: 2, timeout: 25_000 }))),
  batch: { multicall: true },
});

export const C = Object.fromEntries(Object.entries(deployments.contracts).map(([k, v]) => [k, getAddress(v)]));

export const FAUCETS = [
  { name: "Coinbase Developer Platform", url: "https://portal.cdp.coinbase.com/products/faucet" },
  { name: "Alchemy", url: "https://www.alchemy.com/faucets/base-sepolia" },
  { name: "QuickNode", url: "https://faucet.quicknode.com/base/sepolia" },
  { name: "Superchain (Optimism)", url: "https://console.optimism.io/faucet" },
];
