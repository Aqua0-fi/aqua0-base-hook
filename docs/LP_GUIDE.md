# Provide liquidity to Aqua0 pools (testnet)

> Testnet sandbox on Base Sepolia. The tokens are free and worthless. Unaudited.

With Aqua0 you deposit once into the **Shared Liquidity Pool (SLP)**, then choose which pools to back. The same deposit backs all of them at the same time. Your tokens stay in the SLP and are only lent to a pool for the length of one swap.

Everything below can be done in the explorer: **https://aqua0-base-hook.vercel.app**

## 1. Get gas and test tokens

1. Add **Base Sepolia** to your wallet. The explorer does this when you click **Connect wallet**.
2. Get a little Base Sepolia ETH for gas: [Coinbase](https://portal.cdp.coinbase.com/products/faucet) · [Alchemy](https://www.alchemy.com/faucets/base-sepolia) · [Superchain](https://console.optimism.io/faucet).
3. Open **Tokens & faucet** and click **Mint** on mUSDC and mWETH (10,000 mUSDC / 10 mWETH per click). You can also launch your own token there in one transaction.

## 2. Deposit

**Provide liquidity → Deposit / withdraw**: pick a token, enter an amount, **Deposit**. The first time, your wallet asks you to approve the token.

Your deposit shows up as **SLP free**. You can withdraw it at any time.

## 3. Back pools

**Provide liquidity → Back a pool**:
1. Pick a pool. Each pool runs a hook; some are Aqua0 examples, others are built by residents.
2. Pick a price range. Narrow ranges earn more fees per swap but go out of range sooner.
3. Enter the most you want to commit of each token. The preview shows what the range actually uses at the current price.
4. **Back this pool**.

Do it again for other pools with the same deposit. Nothing is locked. If your free balance ever can't cover everything you've backed, each swap scales your share down instead of failing.

## 4. What happens on a swap

When someone swaps in a pool you back:
1. the pool's hook borrows your liquidity from the SLP for that one transaction
2. the trade runs
3. the liquidity goes back with your share of the result: more of the token the trader sold, less of the token they bought, plus the LP fee

Watch it in **Explore → Activity**: each `JIT` line is a swap that used shared liquidity.

## 5. Exit

- **Your positions → Remove** stops backing a range. Your tokens were never moved.
- **Withdraw** takes tokens back to your wallet.
- **Claim fees** pays out earned LP fees.

## Risks (even on testnet)

- **Price risk.** Like any Uniswap v4 position, a range ends up holding more of whichever token is falling. That's impermanent loss.
- **Hook risk.** A pool's hook decides how swaps reach your liquidity (fees, who can swap). Back hooks you understand. Hooks cannot fake swap results or touch your balance in pools you don't back.
- **Unaudited code.** This is a residency sandbox. The final Aqua0 protocol will be different.
