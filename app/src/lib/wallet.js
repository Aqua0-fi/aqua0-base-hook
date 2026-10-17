import { useEffect, useState, useCallback } from "react";
import { createWalletClient, custom, getAddress, numberToHex, maxUint256 } from "viem";
import { CHAIN, EXPLORER, publicClient } from "./config.js";
import { erc20Abi } from "./abis.js";

const eth = () => (typeof window !== "undefined" ? window.ethereum : undefined);

let walletClient = null;
function getWalletClient() {
  if (!eth()) throw new Error("No browser wallet found. Install MetaMask, Rabby or Coinbase Wallet.");
  if (!walletClient) walletClient = createWalletClient({ chain: CHAIN, transport: custom(eth()) });
  return walletClient;
}

async function ensureChain() {
  const hex = numberToHex(CHAIN.id);
  const current = await eth().request({ method: "eth_chainId" });
  if (current === hex) return;
  try {
    await eth().request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
  } catch (e) {
    if (e?.code !== 4902) throw e;
    await eth().request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: hex,
          chainName: "Base Sepolia",
          nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
          rpcUrls: ["https://sepolia.base.org"],
          blockExplorerUrls: [EXPLORER],
        },
      ],
    });
  }
}

export function useWallet() {
  const [account, setAccount] = useState(null);
  const [chainId, setChainId] = useState(null);

  useEffect(() => {
    const p = eth();
    if (!p) return;
    p.request({ method: "eth_accounts" }).then((a) => setAccount(a?.[0] ? getAddress(a[0]) : null)).catch(() => {});
    p.request({ method: "eth_chainId" }).then((c) => setChainId(parseInt(c, 16))).catch(() => {});
    const onAcc = (a) => setAccount(a?.[0] ? getAddress(a[0]) : null);
    const onChain = (c) => setChainId(parseInt(c, 16));
    p.on?.("accountsChanged", onAcc);
    p.on?.("chainChanged", onChain);
    return () => {
      p.removeListener?.("accountsChanged", onAcc);
      p.removeListener?.("chainChanged", onChain);
    };
  }, []);

  const connect = useCallback(async () => {
    if (!eth()) throw new Error("No browser wallet found. Install MetaMask, Rabby or Coinbase Wallet.");
    const a = await eth().request({ method: "eth_requestAccounts" });
    await ensureChain();
    setAccount(getAddress(a[0]));
    setChainId(CHAIN.id);
  }, []);

  return { account, chainId, connect, wrongChain: account && chainId !== CHAIN.id, hasWallet: !!eth() };
}

/** Sends a contract write and waits for the receipt. Returns the receipt. */
export async function write({ account, ...req }) {
  await ensureChain();
  const wc = getWalletClient();
  const { request } = await publicClient.simulateContract({ account, ...req });
  const hash = await wc.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Transaction reverted: ${hash}`);
  return receipt;
}

/** Approves `spender` for max if the current allowance is below `amount` */
export async function ensureAllowance({ account, token, spender, amount, onStatus }) {
  const allowance = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account, spender],
  });
  if (allowance >= amount) return;
  onStatus?.("Approve in your wallet…");
  await write({ account, address: token, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] });
}

export async function watchAsset(token) {
  try {
    await eth()?.request({
      method: "wallet_watchAsset",
      params: { type: "ERC20", options: { address: token.address, symbol: token.symbol.slice(0, 11), decimals: token.decimals } },
    });
  } catch {}
}
