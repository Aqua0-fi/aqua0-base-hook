import { deployments, REPO_URL } from "../lib/config.js";
import { Card, Addr } from "./ui.jsx";

const HOOK = `import {Aqua0BaseHook} from "./Aqua0BaseHook.sol";

contract MyHook is Aqua0BaseHook {
    constructor(IPoolManager pm, SharedLiquidityPool slp) Aqua0BaseHook(pm, slp) {}

    function hookName() public pure override returns (string memory) {
        return "MyHook";                          // shown in the explorer
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        _addVirtualLiquidity(key);                // 1. shared liquidity in
        // ... your logic (fees, checks, pull from a vault) ...
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        (bool hasJIT,) = _removeVirtualLiquidity(key);   // 2. shared liquidity out
        if (hasJIT) _settleVirtualLiquidityDeltas(key);  // 3. settle with the SLP
        // ... your logic (re-park funds, analytics) ...
        return (IHooks.afterSwap.selector, 0);
    }
}`;

const nameMap = {
  poolManager: "Uniswap v4 PoolManager",
  poolSwapTest: "Uniswap PoolSwapTest (swap router)",
  stateView: "Uniswap StateView",
  sharedLiquidityPool: "SharedLiquidityPool (SLP)",
  aqua0Hook: "Aqua0Hook (default)",
  aqua0Lens: "Aqua0Lens (read helpers)",
  aqua0QuoteHelper: "Aqua0QuoteHelper",
  tokenFactory: "TokenFactory",
  swapCounterHook: "SwapCounterHook (example)",
  yieldParkingHook: "YieldParkingHook (example)",
  mockAaveUsdc: "Mock Aave vault (mUSDC)",
  mockAaveWeth: "Mock Aave vault (mWETH)",
};

export default function Build() {
  return (
    <div className="stack">
      <Card title="Build a hook on Aqua0 shared liquidity" subtitle="If you can write a Uniswap v4 hook, you can write an Aqua0 hook.">
        <div className="prose">
          <p>
            <code>Aqua0BaseHook</code> <em>is</em> a Uniswap v4 <code>BaseHook</code> (OpenZeppelin uniswap-hooks). Extend
            it instead of <code>BaseHook</code>, keep three calls in your swap callbacks, and every LP in the Shared
            Liquidity Pool who backs your pool trades through it. The empty contract already works: the defaults do the
            three calls for you.
          </p>
          <ol className="steps">
            <li>
              <strong>Clone and test</strong>
              <pre>
                <code>{`git clone --recurse-submodules ${REPO_URL}
cd aqua0-base-hook
forge test`}</code>
              </pre>
            </li>
            <li>
              <strong>Write your hook</strong> (start from <code>src/examples/HookTemplate.sol</code>)
              <pre>
                <code>{HOOK}</code>
              </pre>
            </li>
            <li>
              <strong>Deploy it, create a pool, back it, swap</strong>: one script, with a testnet-only key holding a
              little Base Sepolia ETH
              <pre>
                <code>{`forge script script/DeployMyHook.s.sol \\
  --rpc-url https://sepolia.base.org --private-key $TESTNET_PK --broadcast`}</code>
              </pre>
            </li>
            <li>
              <strong>Watch it appear</strong> in Explore. Hooks register themselves with the SLP in their constructor;
              pools are picked up from the PoolManager. Nothing to submit.
            </li>
          </ol>
          <h3>Rules of thumb</h3>
          <ul>
            <li>
              Keep <code>beforeSwap</code> and <code>afterSwap</code> on. The hook address must carry exactly your
              permission bits; the script mines a CREATE2 salt for you.
            </li>
            <li>
              Call <code>_addVirtualLiquidity</code> before logic that depends on pool depth, and always pair it with
              remove + settle in <code>_afterSwap</code>, or the swap reverts.
            </li>
            <li>
              Your own PoolManager deltas (fees you take, return deltas) are yours: the helpers only settle the Aqua0
              part.
            </li>
            <li>
              Your hook can be an LP too: deposit into the SLP as itself and <code>addPosition</code> with owner{" "}
              <code>address(this)</code>. See <code>YieldParkingHook</code>: idle funds sit in a yield vault and only
              enter the SLP for the duration of a swap.
            </li>
            <li>
              The SLP never trusts numbers from hooks. It recomputes every swap's result from PoolManager state, so a
              buggy hook can only fail its own swaps.
            </li>
          </ul>
          <h3>What this is, and isn't</h3>
          <ul>
            <li>Unaudited residency build on Base Sepolia. Testnet tokens only.</li>
            <li>Uniswap v4 only, single chain. The cross-chain filler and rebalancing are not included.</li>
            <li>
              The final Aqua0 protocol will change, but the Uniswap v4 hook surface (this base hook) will stay similar.
              Aqua (1inch) support is coming.
            </li>
          </ul>
          <p>
            Full docs: <a href={`${REPO_URL}#readme`}>README</a> ·{" "}
            <a href={`${REPO_URL}/blob/main/docs/BUILDING_HOOKS.md`}>Building hooks</a> ·{" "}
            <a href={`${REPO_URL}/blob/main/docs/USING_THE_SLP.md`}>Using the SLP</a> ·{" "}
            <a href={`${REPO_URL}/blob/main/docs/LP_GUIDE.md`}>LP guide</a>
          </p>
        </div>
      </Card>

      <Card title="Deployed contracts" subtitle={`Base Sepolia (chain ${deployments.chainId}) · from block ${deployments.startBlock}`}>
        <table>
          <tbody>
            {Object.entries(deployments.contracts).map(([k, v]) => (
              <tr key={k}>
                <td>{nameMap[k] || k}</td>
                <td>
                  <Addr a={v} label={v} />
                </td>
              </tr>
            ))}
            {Object.entries(deployments.tokens).map(([k, v]) => (
              <tr key={k}>
                <td>{k} (faucet token)</td>
                <td>
                  <Addr a={v} label={v} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
    </div>
  );
}
