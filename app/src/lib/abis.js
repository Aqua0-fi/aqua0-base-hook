// Human-readable ABIs shared by the indexer (server/) and the web app (src/).
import { parseAbi } from "viem";

const POOL_KEY = "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }";

export const slpAbi = parseAbi([
  POOL_KEY,
  "struct RangeInfo { int24 tickLower; int24 tickUpper; uint128 totalLiquidity; }",
  "function deposit(address token, uint256 amount, address to)",
  "function depositNative(address to) payable",
  "function withdraw(address token, uint256 amount, address from, address to)",
  "function claimFees(address token, address from, address to)",
  "function setOperator(address operator, bool approved)",
  "function addPosition(PoolKey key, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 token0Amount, uint256 token1Amount, address owner) returns (bytes32)",
  "function removePosition(PoolKey key, int24 tickLower, int24 tickUpper, address owner)",
  "function freeBalance(address user, address token) view returns (uint256)",
  "function earnedFees(address user, address token) view returns (uint256)",
  "function totalHoldings(address token) view returns (uint256)",
  "function totalLiabilities(address token) view returns (uint256)",
  "function liquidBalance(address token) view returns (uint256)",
  "function claimBalance(address token) view returns (uint256)",
  "function getPoolRanges(bytes32 poolId) view returns (RangeInfo[])",
  "function getRegisteredHooks() view returns (address[])",
  "function paused() view returns (bool)",
  "function maxRangesPerPool() view returns (uint256)",
  "function maxUsersPerRange() view returns (uint256)",
  "event Deposited(address indexed user, address indexed token, uint256 amount)",
  "event Withdrawn(address indexed user, address indexed token, uint256 amount, address to)",
  "event FeesClaimed(address indexed user, address indexed token, uint256 amount, address to)",
  "event OperatorSet(address indexed owner, address indexed operator, bool approved)",
  "event PositionAdded(address indexed user, bytes32 indexed positionId, bytes32 indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity)",
  "event PositionRemoved(address indexed user, bytes32 indexed positionId, bytes32 indexed poolId)",
  "event HookRegistered(address indexed hook, address indexed deployer)",
  "event SwapAccounted(bytes32 indexed poolId, address indexed hook, int256 net0, int256 net1, uint256 fees0, uint256 fees1)",
  "event Paused(bool paused)",
]);

export const lensAbi = parseAbi([
  "struct PoolState { uint160 sqrtPriceX96; int24 tick; uint24 protocolFee; uint24 lpFee; uint128 liquidity; }",
  "struct PositionView { bytes32 positionId; bytes32 poolId; int24 tickLower; int24 tickUpper; uint128 liquidity; bool active; uint256 amount0Now; uint256 amount1Now; }",
  "function getPoolState(bytes32 poolId) view returns (PoolState)",
  "function liquidityForAmounts(bytes32 poolId, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) view returns (uint128 liquidity, uint256 used0, uint256 used1)",
  "function amountsForLiquidity(bytes32 poolId, int24 tickLower, int24 tickUpper, uint128 liquidity) view returns (uint256 amount0, uint256 amount1)",
  "function getUserPositions(address user) view returns (PositionView[])",
]);

export const quoteAbi = parseAbi([
  POOL_KEY,
  "function quote(PoolKey key, bool zeroForOne, int256 amountSpecified)",
  "error Quote(int256 amount0, int256 amount1, int256 slpDelta0, int256 slpDelta1)",
]);

export const factoryAbi = parseAbi([
  "function createToken(string name, string symbol, uint8 decimals, uint256 faucetUnits) returns (address)",
  "function allTokens() view returns (address[])",
  "event TokenCreated(address indexed token, address indexed creator, string name, string symbol, uint8 decimals, uint256 faucetAmount)",
]);

export const erc20Abi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function faucet()",
  "function faucetAmount() view returns (uint256)",
  "function creator() view returns (address)",
]);

export const hookAbi = parseAbi([
  "function supportsInterface(bytes4 interfaceId) view returns (bool)",
  "function hookName() view returns (string)",
  "function sharedPool() view returns (address)",
  "function poolManager() view returns (address)",
]);

export const poolManagerAbi = parseAbi([
  POOL_KEY,
  "function initialize(PoolKey key, uint160 sqrtPriceX96) returns (int24 tick)",
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
]);

export const swapRouterAbi = parseAbi([
  POOL_KEY,
  "struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }",
  "struct TestSettings { bool takeClaims; bool settleUsingBurn; }",
  "function swap(PoolKey key, SwapParams params, TestSettings testSettings, bytes hookData) payable returns (int256 delta)",
]);

/** ERC165 interface id of IAqua0BaseHookMarker (= selector of isAqua0BaseHook()) */
export const AQUA0_MARKER_ID = "0x46debb1f";

export const MIN_SQRT_PRICE = 4295128739n;
export const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;
export const DYNAMIC_FEE_FLAG = 0x800000;
