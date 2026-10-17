// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAqua0BaseHookMarker} from "./interfaces/IAqua0BaseHookMarker.sol";
import {Aqua0Constants} from "./libraries/Aqua0Constants.sol";
import {SharedLiquidityPool} from "./SharedLiquidityPool.sol";

/// @title Aqua0BaseHook
/// @author Aqua0 Team
/// @notice Extend this instead of Uniswap's BaseHook to give your pool Aqua0 shared liquidity.
///         It *is* a Uniswap v4 BaseHook (OpenZeppelin uniswap-hooks), plus three helpers:
///
///           _addVirtualLiquidity(key)            call in _beforeSwap
///           _removeVirtualLiquidity(key)         call in _afterSwap
///           _settleVirtualLiquidityDeltas(key)   call in _afterSwap if remove returned true
///
///         The default _beforeSwap/_afterSwap below already do exactly that, so the smallest
///         possible Aqua0 hook is an empty contract. Override them to add your own logic and keep
///         the helper calls (or call super).
///
///         Rules of thumb:
///           - Keep beforeSwap and afterSwap enabled in getHookPermissions (checked at deploy).
///           - Call _addVirtualLiquidity before any custom logic that depends on pool depth.
///           - Your own PoolManager deltas (fees you take, return deltas) are untouched: the helpers
///             settle only the virtual-liquidity part.
///
/// @dev UNAUDITED residency build. Single-chain, Uniswap v4 only.
abstract contract Aqua0BaseHook is BaseHook, IAqua0BaseHookMarker {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice The Aqua0 shared liquidity pool every swap borrows from
    SharedLiquidityPool public immutable sharedPool;

    bytes32 private constant JIT_NS = keccak256("aqua0.basehook.jit");
    // per-pool transient fields
    uint256 private constant J_COUNT = 0;
    uint256 private constant J_PENDING = 1;
    uint256 private constant J_CLAIMS0 = 2;
    uint256 private constant J_TOKENS0 = 3;
    uint256 private constant J_CLAIMS1 = 4;
    uint256 private constant J_TOKENS1 = 5;
    uint256 private constant J_OWED0 = 6;
    uint256 private constant J_OWED1 = 7;

    event VirtualLiquidityAdded(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event VirtualLiquidityRemoved(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    /// @notice Net token change of Aqua0's liquidity for one swap, from the SLP's point of view (+ in, - out)
    event NetDeltaSettled(address indexed token0, address indexed token1, int256 delta0, int256 delta1);

    error Aqua0RequiresSwapHooks();
    error WrongPoolManager();
    error VirtualLiquidityAlreadyActive();

    constructor(IPoolManager _poolManager, SharedLiquidityPool _sharedPool) BaseHook(_poolManager) {
        Hooks.Permissions memory p = getHookPermissions();
        if (!p.beforeSwap || !p.afterSwap) revert Aqua0RequiresSwapHooks();
        if (address(_sharedPool.poolManager()) != address(_poolManager)) revert WrongPoolManager();
        sharedPool = _sharedPool;
        _sharedPool.registerHook();
    }

    /// @notice Receives native ETH paid out by the SLP when a pool uses ETH
    receive() external payable virtual {}

    // ─── Permissions ─────────────────────────────────────────────────────────

    /// @notice Default: beforeSwap + afterSwap. Override to enable more callbacks (keep these two on).
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }

    // ─── ERC165 marker ───────────────────────────────────────────────────────

    /// @inheritdoc IAqua0BaseHookMarker
    function isAqua0BaseHook() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IAqua0BaseHookMarker).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Display name for the residency explorer. Override it so people can find your hook.
    function hookName() public view virtual returns (string memory) {
        return "Unnamed Aqua0 hook";
    }

    // ─── Default swap callbacks (override freely) ────────────────────────────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _addVirtualLiquidity(key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        (bool hasJIT,) = _removeVirtualLiquidity(key);
        if (hasJIT) _settleVirtualLiquidityDeltas(key);
        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Aqua0 helpers ───────────────────────────────────────────────────────

    /// @notice Inject virtual JIT liquidity from the SLP into this pool. Call inside _beforeSwap.
    function _addVirtualLiquidity(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        uint256 base = _jitBase(poolId);
        if (_tget(base + J_COUNT) != 0) revert VirtualLiquidityAlreadyActive();

        SharedLiquidityPool.RangeInfo[] memory ranges = sharedPool.preSwap(key);
        uint256 n = ranges.length;
        for (uint256 i = 0; i < n; i++) {
            SharedLiquidityPool.RangeInfo memory r = ranges[i];
            (BalanceDelta mintDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: r.tickLower,
                    tickUpper: r.tickUpper,
                    liquidityDelta: int256(uint256(r.totalLiquidity)),
                    salt: Aqua0Constants.JIT_SALT
                }),
                ""
            );
            uint256 rb = _rangeBase(base, i);
            _tset(rb, uint256(int256(r.tickLower)));
            _tset(rb + 1, uint256(int256(r.tickUpper)));
            _tset(rb + 2, r.totalLiquidity);
            _tset(rb + 3, uint256(BalanceDelta.unwrap(mintDelta)));
            emit VirtualLiquidityAdded(poolId, r.tickLower, r.tickUpper, r.totalLiquidity);
        }
        _tset(base + J_COUNT, n);
    }

    /// @notice Remove the injected liquidity and book the swap result in the SLP. Call early in _afterSwap.
    /// @return hasJIT True if virtual liquidity was used (then call _settleVirtualLiquidityDeltas)
    /// @return lpFee The pool's LP fee from slot0 (informational)
    function _removeVirtualLiquidity(PoolKey calldata key) internal returns (bool hasJIT, uint24 lpFee) {
        PoolId poolId = key.toId();
        uint256 base = _jitBase(poolId);
        uint256 n = _tget(base + J_COUNT);
        if (n == 0) return (false, 0);
        _tset(base + J_COUNT, 0);

        // Let the SLP read our JIT positions (fees, principal) before they are burned.
        sharedPool.checkpoint(key);

        int256 net0;
        int256 net1;
        for (uint256 i = 0; i < n; i++) {
            uint256 rb = _rangeBase(base, i);
            int24 tl = int24(int256(_tget(rb)));
            int24 tu = int24(int256(_tget(rb + 1)));
            uint128 liq = uint128(_tget(rb + 2));
            BalanceDelta mintDelta = BalanceDelta.wrap(int256(_tget(rb + 3)));

            (BalanceDelta burnDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tl, tickUpper: tu, liquidityDelta: -int256(uint256(liq)), salt: Aqua0Constants.JIT_SALT
                }),
                ""
            );
            net0 += int256(mintDelta.amount0()) + int256(burnDelta.amount0());
            net1 += int256(mintDelta.amount1()) + int256(burnDelta.amount1());
            emit VirtualLiquidityRemoved(poolId, tl, tu, liq);
        }

        // Gains are handed to the SLP as ERC6909 claims: works even if the PoolManager has no reserves yet.
        if (net0 > 0) _mintClaimsForPool(key.currency0, uint256(net0));
        if (net1 > 0) _mintClaimsForPool(key.currency1, uint256(net1));

        SharedLiquidityPool.Payout memory p = sharedPool.postSwap(key);
        _tset(base + J_PENDING, 1);
        _tset(base + J_CLAIMS0, p.claims0);
        _tset(base + J_TOKENS0, p.tokens0);
        _tset(base + J_CLAIMS1, p.claims1);
        _tset(base + J_TOKENS1, p.tokens1);
        _tset(base + J_OWED0, net0 < 0 ? uint256(-net0) : 0);
        _tset(base + J_OWED1, net1 < 0 ? uint256(-net1) : 0);

        emit NetDeltaSettled(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), net0, net1);
        (,,, lpFee) = poolManager.getSlot0(poolId);
        return (true, lpFee);
    }

    /// @notice Pay the PoolManager for the virtual liquidity's net outflow with what the SLP sent us.
    ///         Call in _afterSwap after _removeVirtualLiquidity returned true.
    function _settleVirtualLiquidityDeltas(PoolKey calldata key) internal {
        uint256 base = _jitBase(key.toId());
        if (_tget(base + J_PENDING) == 0) return;
        _tset(base + J_PENDING, 0);

        _payPoolManager(key.currency0, _tget(base + J_CLAIMS0), _tget(base + J_TOKENS0), _tget(base + J_OWED0));
        _payPoolManager(key.currency1, _tget(base + J_CLAIMS1), _tget(base + J_TOKENS1), _tget(base + J_OWED1));
    }

    // ─── Internals ───────────────────────────────────────────────────────────

    function _mintClaimsForPool(Currency currency, uint256 amount) private {
        uint256 id = currency.toId();
        poolManager.mint(address(this), id, amount);
        poolManager.approve(address(sharedPool), id, amount);
    }

    function _payPoolManager(Currency currency, uint256 claims, uint256 tokens, uint256 owed) private {
        if (owed == 0) return;
        uint256 fromClaims = claims < owed ? claims : owed;
        if (fromClaims > 0) poolManager.burn(address(this), currency.toId(), fromClaims);
        uint256 rest = owed - fromClaims;
        if (rest == 0) return;
        if (tokens < rest) rest = tokens; // never over-pay; an under-paid delta reverts in the PoolManager
        if (currency.isAddressZero()) {
            poolManager.settle{value: rest}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), rest);
            poolManager.settle();
        }
    }

    function _jitBase(PoolId poolId) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(JIT_NS, poolId)));
    }

    function _rangeBase(uint256 base, uint256 i) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(base, i)));
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
