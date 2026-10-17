// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Aqua0BaseHook} from "../Aqua0BaseHook.sol";
import {SharedLiquidityPool} from "../SharedLiquidityPool.sol";

/// @title YieldParkingHook (example)
/// @notice Idle liquidity earns yield in an ERC4626 vault (think Aave, or an Ondo-style yield token)
///         and is only pulled into Aqua0 for the duration of a swap:
///
///           beforeSwap: redeem from vault -> deposit into SLP -> _addVirtualLiquidity
///           afterSwap:  _removeVirtualLiquidity -> settle -> withdraw from SLP -> deposit back into vault
///
///         The hook itself is the LP: the owner funds it, then `allocate`s a range in this hook's pool.
///         Other LPs can still back the same pool through the SLP as usual.
///
///         Example only: single owner treasury, no share accounting, no slippage protection on vaults.
contract YieldParkingHook is Aqua0BaseHook, Ownable {
    using SafeERC20 for IERC20;

    /// @notice token => yield vault for that token (unset = token is not parked)
    mapping(address => IERC4626) public vaultOf;

    event VaultSet(address indexed token, address indexed vault);
    event Parked(address indexed token, uint256 assets);
    event Unparked(address indexed token, uint256 assets);

    error VaultAssetMismatch();
    error NoVault();

    constructor(IPoolManager _poolManager, SharedLiquidityPool _sharedPool, address _owner)
        Aqua0BaseHook(_poolManager, _sharedPool)
        Ownable(_owner)
    {}

    function hookName() public pure override returns (string memory) {
        return "YieldParkingHook (example: idle funds in a yield vault)";
    }

    // ─── Treasury management (owner) ─────────────────────────────────────────

    function setVault(address token, IERC4626 vault) external onlyOwner {
        if (vault.asset() != token) revert VaultAssetMismatch();
        vaultOf[token] = vault;
        IERC20(token).forceApprove(address(vault), type(uint256).max);
        IERC20(token).forceApprove(address(sharedPool), type(uint256).max);
        emit VaultSet(token, address(vault));
    }

    /// @notice Pull `amount` from the owner and park it in the token's vault
    function fund(address token, uint256 amount) external onlyOwner {
        IERC4626 vault = vaultOf[token];
        if (address(vault) == address(0)) revert NoVault();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        vault.deposit(amount, address(this));
        emit Parked(token, amount);
    }

    /// @notice Take parked funds out of the vault
    function defund(address token, uint256 assets, address to) external onlyOwner {
        vaultOf[token].withdraw(assets, to, address(this));
    }

    /// @notice Back a range of this hook's pool with the parked treasury
    function allocate(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external onlyOwner {
        sharedPool.addPosition(key, tickLower, tickUpper, liquidity, 0, 0, address(this));
    }

    function deallocate(PoolKey calldata key, int24 tickLower, int24 tickUpper) external onlyOwner {
        sharedPool.removePosition(key, tickLower, tickUpper, address(this));
    }

    /// @notice Park everything the hook still has in the SLP (anyone can call, outside of a swap).
    ///         Swap gains arrive as PoolManager claims; the SLP redeems them here.
    function sweep(address token) external {
        _repark(token, true);
    }

    /// @notice Assets currently earning yield in the vault
    function parkedAssets(address token) public view returns (uint256) {
        IERC4626 vault = vaultOf[token];
        if (address(vault) == address(0)) return 0;
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    /// @notice Everything the hook controls: vault + SLP free balance + SLP fees
    function totalManaged(address token) external view returns (uint256) {
        return parkedAssets(token) + sharedPool.freeBalance(address(this), token)
            + sharedPool.earnedFees(address(this), token);
    }

    // ─── Hook flow ───────────────────────────────────────────────────────────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. your logic: wake the capital up
        if (!sharedPool.paused()) {
            _unpark(Currency.unwrap(key.currency0));
            _unpark(Currency.unwrap(key.currency1));
        }
        // 2. Aqua0: inject everyone's shared liquidity (ours included, now that it is in the SLP)
        _addVirtualLiquidity(key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // 1. Aqua0: remove liquidity and settle
        (bool hasJIT,) = _removeVirtualLiquidity(key);
        if (hasJIT) _settleVirtualLiquidityDeltas(key);
        // 2. your logic: put the capital back to work
        _repark(Currency.unwrap(key.currency0), false);
        _repark(Currency.unwrap(key.currency1), false);
        return (IHooks.afterSwap.selector, 0);
    }

    function _unpark(address token) private {
        IERC4626 vault = vaultOf[token];
        if (address(vault) == address(0)) return;
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) return;
        uint256 assets = vault.redeem(shares, address(this), address(this));
        if (assets > 0) sharedPool.deposit(token, assets, address(this));
        emit Unparked(token, assets);
    }

    function _repark(address token, bool everything) private {
        IERC4626 vault = vaultOf[token];
        if (address(vault) == address(0)) return;
        uint256 amount = sharedPool.freeBalance(address(this), token);
        if (!everything) {
            // Mid-swap, gains from this very swap are PoolManager claims that only become redeemable once the
            // swapper has paid, so move just what the SLP holds as plain tokens. `sweep` parks the rest later.
            uint256 liquid = sharedPool.liquidBalance(token);
            if (liquid < amount) amount = liquid;
        }
        if (amount == 0) return;
        sharedPool.withdraw(token, amount, address(this), address(this));
        vault.deposit(amount, address(this));
        emit Parked(token, amount);
    }
}
