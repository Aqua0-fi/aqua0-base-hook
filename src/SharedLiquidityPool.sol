// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IAqua0BaseHookMarker} from "./interfaces/IAqua0BaseHookMarker.sol";
import {Aqua0Constants} from "./libraries/Aqua0Constants.sol";

/// @title SharedLiquidityPool (SLP)
/// @author Aqua0 Team
/// @notice One contract that holds every LP's tokens and lends them, just in time, to any number of
///         Uniswap v4 pools whose hook extends Aqua0BaseHook.
///
///         LP lifecycle:
///           1. `deposit` tokens (they become your `freeBalance`).
///           2. `addPosition` to back a (v4 pool, tick range) with virtual liquidity. Nothing moves:
///              the same free balance can back positions in many pools at once.
///           3. On every swap in that pool the hook asks the SLP which ranges to inject, adds them to the
///              PoolManager for the duration of the swap, removes them afterwards and settles only the net
///              token change with the SLP. Your share of that change (inventory shift + LP fees) is booked
///              to your `freeBalance` / `earnedFees`.
///           4. `removePosition`, `claimFees`, `withdraw` to exit.
///
///         Hook protocol (called by Aqua0BaseHook, you never call these yourself):
///           preSwap -> [hook mints JIT liquidity] -> swap -> checkpoint -> [hook burns JIT liquidity] -> postSwap
///
///         Safety properties for permissionless hooks:
///           - A hook can only open a session for a pool where it is `key.hooks`.
///           - The SLP never trusts amounts reported by a hook. Mint cost, burn proceeds and LP fees are
///             recomputed from PoolManager state with the same math the PoolManager uses.
///           - Each LP's virtual liquidity is scaled so its worst-case loss fits inside its free balance,
///             so one LP can never spend another LP's tokens.
///           - After every swap the SLP checks that its liabilities grew no faster than its holdings.
///           - Gains are delivered as PoolManager ERC6909 claims, so swaps work even when the PoolManager
///             holds no reserves of a token yet (fresh testnet tokens). Claims are redeemed on withdraw.
///
/// @dev UNAUDITED residency build. Single-chain, Uniswap v4 only. No cross-chain filler.
contract SharedLiquidityPool is Ownable, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    // ─── Structs ─────────────────────────────────────────────────────────────

    /// @notice A user's virtual position in a specific pool at a specific tick range
    struct UserPosition {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityShares; // virtual liquidity requested
        uint256 token0Initial; // token0 the user earmarked when opening (informational)
        uint256 token1Initial; // token1 the user earmarked when opening (informational)
        bool active;
    }

    /// @notice Aggregated liquidity across all users for a (pool, tickLower, tickUpper) range
    struct RangeInfo {
        int24 tickLower;
        int24 tickUpper;
        uint128 totalLiquidity;
    }

    /// @notice How the SLP paid a hook for a swap's net outflow (see `postSwap`)
    struct Payout {
        uint256 claims0; // ERC6909 claims of currency0 transferred to the hook (burn them)
        uint256 tokens0; // currency0 transferred to the hook (settle them)
        uint256 claims1;
        uint256 tokens1;
    }

    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Wei of headroom reserved per token per position when sizing virtual liquidity (rounding)
    uint256 internal constant ROUNDING_MARGIN = 4;

    bytes32 private constant SESSION_NS = keccak256("aqua0.slp.session");
    bytes32 private constant BUDGET_NS = keccak256("aqua0.slp.budget");
    uint256 private constant ACTIVE_SESSIONS_SLOT = uint256(keccak256("aqua0.slp.activeSessions"));
    uint256 private constant NONCE_SLOT = uint256(keccak256("aqua0.slp.nonce"));

    // session fields (offsets from the session base slot)
    uint256 private constant S_HOOK = 0;
    uint256 private constant S_STAGE = 1;
    uint256 private constant S_COUNT = 2;
    // range fields (offsets from a range base slot)
    uint256 private constant R_TICK_LOWER = 0;
    uint256 private constant R_TICK_UPPER = 1;
    uint256 private constant R_LIQUIDITY = 2;
    uint256 private constant R_MINT0 = 3;
    uint256 private constant R_MINT1 = 4;
    uint256 private constant R_USERS = 5;
    uint256 private constant R_PRINCIPAL0 = 6;
    uint256 private constant R_PRINCIPAL1 = 7;
    uint256 private constant R_FEES0 = 8;
    uint256 private constant R_FEES1 = 9;

    uint256 private constant STAGE_OPEN = 1;
    uint256 private constant STAGE_CHECKPOINTED = 2;

    // ─── Immutables / config ─────────────────────────────────────────────────

    /// @notice The Uniswap v4 PoolManager every Aqua0 hook on this chain must use
    IPoolManager public immutable poolManager;

    /// @notice Max distinct tick ranges with active positions per pool (bounds swap gas)
    uint256 public maxRangesPerPool = 16;

    /// @notice Max LPs per (pool, range) (bounds swap gas)
    uint256 public maxUsersPerRange = 16;

    /// @notice When paused: no new deposits/positions and swaps run without virtual liquidity.
    ///         Withdrawals always stay open.
    bool public paused;

    // ─── LP state ────────────────────────────────────────────────────────────

    /// @notice user => token => free (withdrawable) balance. address(0) = native ETH.
    mapping(address => mapping(address => uint256)) public freeBalance;

    /// @notice user => token => LP fees earned and not yet claimed
    mapping(address => mapping(address => uint256)) public earnedFees;

    /// @notice token => sum of all users' freeBalance
    mapping(address => uint256) public totalFreeBalance;

    /// @notice token => sum of all users' earnedFees
    mapping(address => uint256) public totalEarnedFees;

    /// @notice owner => operator => approved. Operators may withdraw, claim and manage positions for the owner.
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice user => positionId => UserPosition
    mapping(address => mapping(bytes32 => UserPosition)) public userPositions;

    mapping(address => bytes32[]) private _userPositionIds;
    mapping(address => mapping(bytes32 => bool)) private _knownPosition;

    /// @notice poolId => rangeKey => RangeInfo. rangeKey = keccak256(abi.encode(tickLower, tickUpper))
    mapping(PoolId => mapping(bytes32 => RangeInfo)) public aggregatedRanges;

    mapping(PoolId => bytes32[]) private _poolRangeKeys;
    mapping(PoolId => mapping(bytes32 => bool)) private _rangeExists;
    mapping(PoolId => mapping(bytes32 => address[])) private _rangeUsers;

    // ─── Hook registry (informational, for indexers) ─────────────────────────

    address[] private _registeredHooks;

    /// @notice hook => called registerHook() (unverified; check supportsInterface before trusting)
    mapping(address => bool) public isRegisteredHook;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, address to);
    event FeesClaimed(address indexed user, address indexed token, uint256 amount, address to);
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event PositionAdded(
        address indexed user,
        bytes32 indexed positionId,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event PositionRemoved(address indexed user, bytes32 indexed positionId, PoolId indexed poolId);
    event HookRegistered(address indexed hook, address indexed deployer);
    /// @notice One per swap that used virtual liquidity. Amounts are the SLP's net change (+ in, - out).
    event SwapAccounted(
        PoolId indexed poolId, address indexed hook, int256 net0, int256 net1, uint256 fees0, uint256 fees1
    );
    event Paused(bool paused);
    event LimitsSet(uint256 maxRangesPerPool, uint256 maxUsersPerRange);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error NotAuthorized();
    error InsufficientFreeBalance();
    error PositionNotFound();
    error PositionAlreadyExists();
    error InvalidTicks();
    error TransferFailed();
    error NotAqua0Hook();
    error CallerNotPoolHook();
    error PoolNotInitialized();
    error SessionAlreadyOpen();
    error NoOpenSession();
    error SwapInProgress();
    error VirtualLiquidityMissing();
    error Insolvent();
    error InsufficientLiquidity();
    error TooManyRanges();
    error TooManyUsersInRange();
    error IsPaused();
    error NotPoolManager();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier noActiveSwap() {
        if (_tget(ACTIVE_SESSIONS_SLOT) != 0) revert SwapInProgress();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address _owner, IPoolManager _poolManager) Ownable(_owner) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
    }

    receive() external payable {}

    // ═════════════════════════════════════════════════════════════════════════
    //                                   LPs
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Deposit an ERC20 into the SLP, credited to `to`'s free balance
    function deposit(address token, uint256 amount, address to) external nonReentrant whenNotPaused {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;

        _creditFree(to, token, received);
        emit Deposited(to, token, received);
    }

    /// @notice Deposit native ETH, credited to `to`'s free balance under token address(0)
    function depositNative(address to) external payable nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();
        _creditFree(to, address(0), msg.value);
        emit Deposited(to, address(0), msg.value);
    }

    /// @notice Withdraw from `from`'s free balance to `to`. Caller must be `from` or its operator.
    function withdraw(address token, uint256 amount, address from, address to) external nonReentrant noActiveSwap {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _checkOwnerOrOperator(from);
        if (freeBalance[from][token] < amount) revert InsufficientFreeBalance();

        freeBalance[from][token] -= amount;
        totalFreeBalance[token] -= amount;
        _payOut(token, to, amount);

        emit Withdrawn(from, token, amount, to);
    }

    /// @notice Claim `from`'s accumulated LP fees for `token` to `to`
    function claimFees(address token, address from, address to) external nonReentrant noActiveSwap {
        if (to == address(0)) revert ZeroAddress();
        _checkOwnerOrOperator(from);
        uint256 amount = earnedFees[from][token];
        if (amount == 0) revert ZeroAmount();

        earnedFees[from][token] = 0;
        totalEarnedFees[token] -= amount;
        _payOut(token, to, amount);

        emit FeesClaimed(from, token, amount, to);
    }

    /// @notice Let `operator` withdraw, claim and manage positions on your behalf (e.g. a hook or vault)
    function setOperator(address operator, bool approved) external {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    /// @notice Back a (v4 pool, tick range) with virtual liquidity from your free balance.
    ///         Tokens do not move. At swap time the liquidity is scaled down if your free balance
    ///         can no longer cover it, so it is safe to over-allocate across many pools.
    /// @param key          The v4 PoolKey. `key.hooks` must be an Aqua0 hook and the pool must be initialized.
    /// @param tickLower    Lower tick, multiple of key.tickSpacing
    /// @param tickUpper    Upper tick, multiple of key.tickSpacing, > tickLower
    /// @param liquidity    v4 liquidity units to provide
    /// @param token0Amount token0 you mean to back this with (must be <= free balance; informational)
    /// @param token1Amount token1 you mean to back this with (must be <= free balance; informational)
    /// @param owner        Position owner (msg.sender or an owner that approved msg.sender as operator)
    function addPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 token0Amount,
        uint256 token1Amount,
        address owner
    ) external nonReentrant whenNotPaused noActiveSwap returns (bytes32 positionId) {
        _checkOwnerOrOperator(owner);
        _validateTicks(key.tickSpacing, tickLower, tickUpper);
        if (liquidity == 0) revert ZeroAmount();
        _requireAqua0Hook(address(key.hooks));

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        if (freeBalance[owner][Currency.unwrap(key.currency0)] < token0Amount) revert InsufficientFreeBalance();
        if (freeBalance[owner][Currency.unwrap(key.currency1)] < token1Amount) revert InsufficientFreeBalance();

        positionId = _positionId(owner, poolId, tickLower, tickUpper);
        UserPosition storage pos = userPositions[owner][positionId];
        if (pos.active) revert PositionAlreadyExists();

        bytes32 rangeKey = _rangeKey(tickLower, tickUpper);
        if (!_rangeExists[poolId][rangeKey]) {
            if (_poolRangeKeys[poolId].length >= maxRangesPerPool) revert TooManyRanges();
            _rangeExists[poolId][rangeKey] = true;
            _poolRangeKeys[poolId].push(rangeKey);
            aggregatedRanges[poolId][rangeKey] =
                RangeInfo({tickLower: tickLower, tickUpper: tickUpper, totalLiquidity: 0});
        }
        address[] storage users = _rangeUsers[poolId][rangeKey];
        if (users.length >= maxUsersPerRange) revert TooManyUsersInRange();
        users.push(owner);
        aggregatedRanges[poolId][rangeKey].totalLiquidity += liquidity;

        pos.poolId = poolId;
        pos.tickLower = tickLower;
        pos.tickUpper = tickUpper;
        pos.liquidityShares = liquidity;
        pos.token0Initial = token0Amount;
        pos.token1Initial = token1Amount;
        pos.active = true;
        if (!_knownPosition[owner][positionId]) {
            _knownPosition[owner][positionId] = true;
            _userPositionIds[owner].push(positionId);
        }

        emit PositionAdded(owner, positionId, poolId, tickLower, tickUpper, liquidity);
    }

    /// @notice Stop backing a range. Your free balance is unaffected (it never left).
    function removePosition(PoolKey calldata key, int24 tickLower, int24 tickUpper, address owner)
        external
        nonReentrant
        noActiveSwap
    {
        _checkOwnerOrOperator(owner);
        PoolId poolId = key.toId();
        bytes32 positionId = _positionId(owner, poolId, tickLower, tickUpper);
        UserPosition storage pos = userPositions[owner][positionId];
        if (!pos.active) revert PositionNotFound();

        uint128 liquidity = pos.liquidityShares;
        pos.active = false;
        pos.liquidityShares = 0;
        pos.token0Initial = 0;
        pos.token1Initial = 0;

        bytes32 rangeKey = _rangeKey(tickLower, tickUpper);
        aggregatedRanges[poolId][rangeKey].totalLiquidity -= liquidity;
        _removeAddress(_rangeUsers[poolId][rangeKey], owner);
        if (_rangeUsers[poolId][rangeKey].length == 0) {
            _removeKey(_poolRangeKeys[poolId], rangeKey);
            delete _rangeExists[poolId][rangeKey];
            delete aggregatedRanges[poolId][rangeKey];
        }

        emit PositionRemoved(owner, positionId, poolId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                            Hook protocol
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Called once from a hook's constructor so indexers can discover it. Unverified.
    function registerHook() external {
        if (isRegisteredHook[msg.sender]) return;
        isRegisteredHook[msg.sender] = true;
        _registeredHooks.push(msg.sender);
        emit HookRegistered(msg.sender, tx.origin);
    }

    /// @notice Step 1 (beforeSwap). Returns the ranges the hook must add with salt JIT_SALT.
    ///         Each LP's liquidity is scaled so its current-price cost fits in its free balance.
    ///         Returns an empty array (and opens no session) when there is nothing to inject.
    function preSwap(PoolKey calldata key) external nonReentrant returns (RangeInfo[] memory ranges) {
        if (msg.sender != address(key.hooks)) revert CallerNotPoolHook();
        _requireAqua0Hook(msg.sender);

        PoolId poolId = key.toId();
        uint256 sb = _sessionBase(poolId);
        if (_tget(sb + S_STAGE) != 0) revert SessionAlreadyOpen();
        if (paused) return ranges;

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        uint256 nonce = _tget(NONCE_SLOT) + 1;
        _tset(NONCE_SLOT, nonce);

        bytes32[] storage keys = _poolRangeKeys[poolId];
        RangeInfo[] memory tmp = new RangeInfo[](keys.length);
        uint256 n;
        SizingContext memory ctx = SizingContext({
            poolId: poolId,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            token0: Currency.unwrap(key.currency0),
            token1: Currency.unwrap(key.currency1),
            nonce: nonce,
            perUserCap: _perUserLiquidityCap(key.tickSpacing)
        });

        for (uint256 i = 0; i < keys.length; i++) {
            RangeInfo storage r = aggregatedRanges[poolId][keys[i]];
            if (r.totalLiquidity == 0) continue;

            uint256 rb = _rangeBase(sb, n);
            uint128 total = _sizeRange(ctx, keys[i], r.tickLower, r.tickUpper, rb);
            if (total == 0) continue;

            (int256 m0, int256 m1) = _principalDelta(sqrtPriceX96, tick, r.tickLower, r.tickUpper, _toInt128(total));
            _tset(rb + R_TICK_LOWER, uint256(int256(r.tickLower)));
            _tset(rb + R_TICK_UPPER, uint256(int256(r.tickUpper)));
            _tset(rb + R_LIQUIDITY, total);
            _tset(rb + R_MINT0, uint256(m0));
            _tset(rb + R_MINT1, uint256(m1));

            tmp[n] = RangeInfo({tickLower: r.tickLower, tickUpper: r.tickUpper, totalLiquidity: total});
            n++;
        }

        if (n == 0) return new RangeInfo[](0);

        _tset(sb + S_HOOK, uint256(uint160(msg.sender)));
        _tset(sb + S_STAGE, STAGE_OPEN);
        _tset(sb + S_COUNT, n);
        _tset(ACTIVE_SESSIONS_SLOT, _tget(ACTIVE_SESSIONS_SLOT) + 1);

        ranges = new RangeInfo[](n);
        for (uint256 i = 0; i < n; i++) {
            ranges[i] = tmp[i];
        }
    }

    /// @notice Step 2 (afterSwap, before the hook burns). Reads the hook's JIT positions from the
    ///         PoolManager and records the exact burn proceeds and LP fees each range will produce.
    function checkpoint(PoolKey calldata key) external nonReentrant {
        PoolId poolId = key.toId();
        uint256 sb = _sessionBase(poolId);
        if (_tget(sb + S_STAGE) != STAGE_OPEN || address(uint160(_tget(sb + S_HOOK))) != msg.sender) {
            revert NoOpenSession();
        }

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint256 n = _tget(sb + S_COUNT);
        for (uint256 i = 0; i < n; i++) {
            uint256 rb = _rangeBase(sb, i);
            int24 tl = int24(int256(_tget(rb + R_TICK_LOWER)));
            int24 tu = int24(int256(_tget(rb + R_TICK_UPPER)));
            uint128 liq = uint128(_tget(rb + R_LIQUIDITY));

            (uint128 posLiq, uint256 last0, uint256 last1) =
                poolManager.getPositionInfo(poolId, msg.sender, tl, tu, Aqua0Constants.JIT_SALT);
            if (posLiq < liq) revert VirtualLiquidityMissing();
            (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, tl, tu);
            uint256 fees0;
            uint256 fees1;
            unchecked {
                fees0 = FullMath.mulDiv(inside0 - last0, liq, FixedPoint128.Q128);
                fees1 = FullMath.mulDiv(inside1 - last1, liq, FixedPoint128.Q128);
            }

            (int256 b0, int256 b1) = _principalDelta(sqrtPriceX96, tick, tl, tu, -_toInt128(liq));
            _tset(rb + R_PRINCIPAL0, uint256(int256(_tget(rb + R_MINT0)) + b0));
            _tset(rb + R_PRINCIPAL1, uint256(int256(_tget(rb + R_MINT1)) + b1));
            _tset(rb + R_FEES0, fees0);
            _tset(rb + R_FEES1, fees1);
        }
        _tset(sb + S_STAGE, STAGE_CHECKPOINTED);
    }

    /// @notice Step 3 (afterSwap, after the hook burned). Books every LP's share of the swap, then
    ///         settles the net with the hook: pulls ERC6909 claims for net inflows (the hook must have
    ///         minted and approved them) and pays net outflows to the hook (claims first, then tokens).
    function postSwap(PoolKey calldata key) external nonReentrant returns (Payout memory payout) {
        PoolId poolId = key.toId();
        uint256 sb = _sessionBase(poolId);
        if (_tget(sb + S_STAGE) != STAGE_CHECKPOINTED || address(uint160(_tget(sb + S_HOOK))) != msg.sender) {
            revert NoOpenSession();
        }
        _tset(sb + S_STAGE, 0);
        _tset(ACTIVE_SESSIONS_SLOT, _tget(ACTIVE_SESSIONS_SLOT) - 1);

        Ledger memory l0;
        Ledger memory l1;
        l0.token = Currency.unwrap(key.currency0);
        l1.token = Currency.unwrap(key.currency1);

        uint256 n = _tget(sb + S_COUNT);
        for (uint256 i = 0; i < n; i++) {
            _bookRange(_rangeBase(sb, i), l0, l1);
        }

        // Liabilities may never grow faster than holdings.
        if (int256(l0.credits) - int256(l0.debits) > l0.net) revert Insolvent();
        if (int256(l1.credits) - int256(l1.debits) > l1.net) revert Insolvent();

        (payout.claims0, payout.tokens0) = _settleWithHook(key.currency0, l0.net);
        (payout.claims1, payout.tokens1) = _settleWithHook(key.currency1, l1.net);

        emit SwapAccounted(poolId, msg.sender, l0.net, l1.net, l0.fees, l1.fees);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only used to redeem the SLP's ERC6909 claims into tokens during withdrawals.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                  Admin
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Emergency switch for the residency deployment. Withdrawals are never paused.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function setLimits(uint256 _maxRangesPerPool, uint256 _maxUsersPerRange) external onlyOwner {
        if (_maxRangesPerPool == 0 || _maxUsersPerRange == 0) revert ZeroAmount();
        maxRangesPerPool = _maxRangesPerPool;
        maxUsersPerRange = _maxUsersPerRange;
        emit LimitsSet(_maxRangesPerPool, _maxUsersPerRange);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                  Views
    // ═════════════════════════════════════════════════════════════════════════

    function getUserPositionIds(address user) external view returns (bytes32[] memory) {
        return _userPositionIds[user];
    }

    function getPoolRangeKeys(PoolId poolId) external view returns (bytes32[] memory) {
        return _poolRangeKeys[poolId];
    }

    function getPoolRanges(PoolId poolId) external view returns (RangeInfo[] memory ranges) {
        bytes32[] storage keys = _poolRangeKeys[poolId];
        ranges = new RangeInfo[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            ranges[i] = aggregatedRanges[poolId][keys[i]];
        }
    }

    function getRangeUsers(PoolId poolId, bytes32 rangeKey) external view returns (address[] memory) {
        return _rangeUsers[poolId][rangeKey];
    }

    function getRegisteredHooks() external view returns (address[] memory) {
        return _registeredHooks;
    }

    /// @notice Tokens the SLP holds directly (ERC20 balance or ETH)
    function liquidBalance(address token) public view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @notice PoolManager ERC6909 claims the SLP holds for `token` (redeemed automatically on withdraw)
    function claimBalance(address token) public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(token).toId());
    }

    function totalHoldings(address token) public view returns (uint256) {
        return liquidBalance(token) + claimBalance(token);
    }

    function totalLiabilities(address token) public view returns (uint256) {
        return totalFreeBalance[token] + totalEarnedFees[token];
    }

    function positionIdOf(address user, PoolId poolId, int24 tickLower, int24 tickUpper)
        external
        pure
        returns (bytes32)
    {
        return _positionId(user, poolId, tickLower, tickUpper);
    }

    function rangeKeyOf(int24 tickLower, int24 tickUpper) external pure returns (bytes32) {
        return _rangeKey(tickLower, tickUpper);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                Internals
    // ═════════════════════════════════════════════════════════════════════════

    struct SizingContext {
        PoolId poolId;
        uint160 sqrtPriceX96;
        int24 tick;
        address token0;
        address token1;
        uint256 nonce;
        uint128 perUserCap;
    }

    struct Ledger {
        address token;
        int256 net; // SLP holdings change (+ in, - out)
        uint256 credits; // liabilities added (freeBalance gains + fees)
        uint256 debits; // liabilities removed (freeBalance losses)
        uint256 fees;
    }

    /// @dev Sizes every LP in a range against its remaining budget and stores (user, liquidity) pairs.
    function _sizeRange(SizingContext memory ctx, bytes32 rangeKey, int24 tl, int24 tu, uint256 rb)
        private
        returns (uint128 total)
    {
        address[] storage users = _rangeUsers[ctx.poolId][rangeKey];
        uint256 count;
        for (uint256 j = 0; j < users.length; j++) {
            address user = users[j];
            UserPosition storage pos = userPositions[user][_positionId(user, ctx.poolId, tl, tu)];
            if (!pos.active || pos.liquidityShares == 0) continue;

            uint128 liq = pos.liquidityShares < ctx.perUserCap ? pos.liquidityShares : ctx.perUserCap;
            (uint256 need0, uint256 need1) = _mintCost(ctx.sqrtPriceX96, ctx.tick, tl, tu, liq);

            uint256 b0 = _budget(ctx.nonce, user, ctx.token0);
            uint256 b1 = _budget(ctx.nonce, user, ctx.token1);
            uint256 scaled = _fitToBudget(liq, need0, b0);
            scaled = Math.min(scaled, _fitToBudget(liq, need1, b1));
            if (scaled == 0) continue;

            if (need0 > 0) _setBudget(ctx.nonce, user, ctx.token0, b0 - _consumed(need0, scaled, liq));
            if (need1 > 0) _setBudget(ctx.nonce, user, ctx.token1, b1 - _consumed(need1, scaled, liq));

            uint256 ub = _userBase(rb, count);
            _tset(ub, uint256(uint160(user)));
            _tset(ub + 1, scaled);
            count++;
            total += uint128(scaled);
        }
        _tset(rb + R_USERS, count);
    }

    /// @dev Largest liquidity <= liq whose cost (+margin) fits in budget
    function _fitToBudget(uint128 liq, uint256 need, uint256 budget) private pure returns (uint256) {
        if (need == 0) return liq;
        if (budget <= ROUNDING_MARGIN) return 0;
        uint256 avail = budget - ROUNDING_MARGIN;
        if (avail >= need) return liq;
        return FullMath.mulDiv(liq, avail, need);
    }

    function _consumed(uint256 need, uint256 scaled, uint128 liq) private pure returns (uint256) {
        return FullMath.mulDivRoundingUp(need, scaled, liq) + ROUNDING_MARGIN;
    }

    /// @dev Distributes one range's result to its LPs and accumulates totals
    function _bookRange(uint256 rb, Ledger memory l0, Ledger memory l1) private {
        uint256 total = _tget(rb + R_LIQUIDITY);
        int256 p0 = int256(_tget(rb + R_PRINCIPAL0));
        int256 p1 = int256(_tget(rb + R_PRINCIPAL1));
        uint256 f0 = _tget(rb + R_FEES0);
        uint256 f1 = _tget(rb + R_FEES1);
        l0.net += p0 + int256(f0);
        l1.net += p1 + int256(f1);
        l0.fees += f0;
        l1.fees += f1;

        uint256 count = _tget(rb + R_USERS);
        for (uint256 j = 0; j < count; j++) {
            uint256 ub = _userBase(rb, j);
            address user = address(uint160(_tget(ub)));
            uint256 liq = _tget(ub + 1);
            _applyShare(user, l0, p0, f0, liq, total);
            _applyShare(user, l1, p1, f1, liq, total);
        }
    }

    function _applyShare(address user, Ledger memory l, int256 principal, uint256 fees, uint256 liq, uint256 total)
        private
    {
        if (principal > 0) {
            uint256 gain = FullMath.mulDiv(uint256(principal), liq, total);
            if (gain > 0) {
                _creditFree(user, l.token, gain);
                l.credits += gain;
            }
        } else if (principal < 0) {
            uint256 loss = FullMath.mulDivRoundingUp(uint256(-principal), liq, total);
            uint256 bal = freeBalance[user][l.token];
            uint256 taken = loss < bal ? loss : bal;
            freeBalance[user][l.token] = bal - taken;
            totalFreeBalance[l.token] -= taken;
            l.debits += taken;
        }
        if (fees > 0) {
            uint256 fee = FullMath.mulDiv(fees, liq, total);
            if (fee > 0) {
                earnedFees[user][l.token] += fee;
                totalEarnedFees[l.token] += fee;
                l.credits += fee;
            }
        }
    }

    function _settleWithHook(Currency currency, int256 net) private returns (uint256 claimsPaid, uint256 tokensPaid) {
        uint256 id = currency.toId();
        if (net > 0) {
            poolManager.transferFrom(msg.sender, address(this), id, uint256(net));
        } else if (net < 0) {
            uint256 owed = uint256(-net);
            uint256 claims = poolManager.balanceOf(address(this), id);
            claimsPaid = claims < owed ? claims : owed;
            if (claimsPaid > 0) poolManager.transfer(msg.sender, id, claimsPaid);
            tokensPaid = owed - claimsPaid;
            if (tokensPaid > 0) {
                address token = Currency.unwrap(currency);
                if (liquidBalance(token) < tokensPaid) revert InsufficientLiquidity();
                _send(token, msg.sender, tokensPaid);
            }
        }
    }

    /// @dev Pays `amount` of `token` to `to`, using held tokens first and redeeming claims for the rest
    function _payOut(address token, address to, uint256 amount) private {
        uint256 liquid = liquidBalance(token);
        uint256 direct = liquid < amount ? liquid : amount;
        if (direct > 0) _send(token, to, direct);
        uint256 rest = amount - direct;
        if (rest == 0) return;

        if (claimBalance(token) < rest) revert InsufficientLiquidity();
        Currency currency = Currency.wrap(token);
        if (poolManager.isUnlocked()) {
            // Already inside someone's unlock (e.g. a hook withdrawing in afterSwap): redeem directly.
            poolManager.burn(address(this), currency.toId(), rest);
            poolManager.take(currency, to, rest);
        } else {
            poolManager.unlock(abi.encode(currency, to, rest));
        }
    }

    function _send(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _creditFree(address user, address token, uint256 amount) private {
        freeBalance[user][token] += amount;
        totalFreeBalance[token] += amount;
    }

    /// @dev Exactly what PoolManager computes for a modifyLiquidity principal delta (caller's view)
    function _principalDelta(uint160 sqrtPriceX96, int24 tick, int24 tl, int24 tu, int128 liquidityDelta)
        private
        pure
        returns (int256 d0, int256 d1)
    {
        if (tick < tl) {
            d0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liquidityDelta
            );
        } else if (tick < tu) {
            d0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tu), liquidityDelta);
            d1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tl), sqrtPriceX96, liquidityDelta);
        } else {
            d1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liquidityDelta
            );
        }
    }

    function _mintCost(uint160 sqrtPriceX96, int24 tick, int24 tl, int24 tu, uint128 liq)
        private
        pure
        returns (uint256 need0, uint256 need1)
    {
        (int256 d0, int256 d1) = _principalDelta(sqrtPriceX96, tick, tl, tu, _toInt128(liq));
        need0 = uint256(-d0);
        need1 = uint256(-d1);
    }

    /// @dev Keeps the summed JIT liquidity of a whole pool well under the PoolManager's per-tick limit
    function _perUserLiquidityCap(int24 tickSpacing) private view returns (uint128) {
        uint256 cap = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing) / (2 * maxRangesPerPool * maxUsersPerRange);
        return cap > type(uint128).max ? type(uint128).max : uint128(cap);
    }

    function _validateTicks(int24 spacing, int24 tickLower, int24 tickUpper) private pure {
        if (tickLower >= tickUpper) revert InvalidTicks();
        if (tickLower < TickMath.minUsableTick(spacing) || tickUpper > TickMath.maxUsableTick(spacing)) {
            revert InvalidTicks();
        }
        if (tickLower % spacing != 0 || tickUpper % spacing != 0) revert InvalidTicks();
    }

    function _checkOwnerOrOperator(address owner) private view {
        if (msg.sender != owner && !isOperator[owner][msg.sender]) revert NotAuthorized();
    }

    function _requireAqua0Hook(address hook) private view {
        if (hook.code.length == 0) revert NotAqua0Hook();
        try IERC165(hook).supportsInterface(type(IAqua0BaseHookMarker).interfaceId) returns (bool ok) {
            if (!ok) revert NotAqua0Hook();
        } catch {
            revert NotAqua0Hook();
        }
    }

    function _removeAddress(address[] storage list, address value) private {
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == value) {
                list[i] = list[len - 1];
                list.pop();
                return;
            }
        }
    }

    function _removeKey(bytes32[] storage list, bytes32 value) private {
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == value) {
                list[i] = list[len - 1];
                list.pop();
                return;
            }
        }
    }

    function _positionId(address user, PoolId poolId, int24 tickLower, int24 tickUpper) private pure returns (bytes32) {
        return keccak256(abi.encode(user, poolId, tickLower, tickUpper));
    }

    function _rangeKey(int24 tickLower, int24 tickUpper) private pure returns (bytes32) {
        return keccak256(abi.encode(tickLower, tickUpper));
    }

    function _toInt128(uint128 x) private pure returns (int128) {
        return SafeCast.toInt128(SafeCast.toInt256(uint256(x)));
    }

    // ─── Transient storage ───────────────────────────────────────────────────

    function _sessionBase(PoolId poolId) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(SESSION_NS, poolId)));
    }

    function _rangeBase(uint256 sessionBase, uint256 i) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(sessionBase, "range", i)));
    }

    function _userBase(uint256 rangeBase, uint256 j) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(rangeBase, "user", j)));
    }

    /// @dev Per-swap spending budget; lazily initialised from freeBalance (stored +1 so 0 means unset)
    function _budget(uint256 nonce, address user, address token) private view returns (uint256) {
        uint256 v = _tget(_budgetSlot(nonce, user, token));
        return v == 0 ? freeBalance[user][token] : v - 1;
    }

    function _setBudget(uint256 nonce, address user, address token, uint256 value) private {
        _tset(_budgetSlot(nonce, user, token), value + 1);
    }

    function _budgetSlot(uint256 nonce, address user, address token) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(BUDGET_NS, nonce, user, token)));
    }

    function _tget(uint256 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tset(uint256 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }
}
