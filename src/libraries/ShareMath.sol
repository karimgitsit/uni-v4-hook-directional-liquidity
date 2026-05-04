// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title ShareMath
/// @notice Pure helpers for the per-mode share accounting and fee accumulator
///         pattern used by `DirectionalLiquidityHook`.
/// @dev    Accumulator pattern (à la Synthetix StakingRewards / MasterChef):
///         - `feePerShareCumulative{0,1}` ticks up by `Δfees × 2^128 /
///           totalShares` every time fees arrive.
///         - On deposit/withdraw, an LP's owed fees =
///           `(currentCumulative − feeSnapshot) × shares / 2^128`.
///         - The 2^128 scaling preserves precision when a single fee unit is
///           split across many shares.
library ShareMath {
    /// @dev Fixed-point scale for the accumulator. Same as v4 fee growth.
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Compute shares to issue for a follow-on deposit, pro-rata
    ///         against the mode's current liquidity.
    /// @param  depositLiquidity Liquidity (v4 units) being added to the
    ///         mode's position by this deposit.
    /// @param  totalShares      Mode's current total share count.
    /// @param  modeLiquidity    Mode's current position liquidity *before*
    ///         this deposit is added.
    /// @return sharesIssued     Shares to mint to the depositor.
    /// @dev    Reverts on first deposit (`totalShares == 0`) — callers must
    ///         handle the 1:1 init path separately.
    function sharesForDeposit(uint128 depositLiquidity, uint128 totalShares, uint128 modeLiquidity)
        internal
        pure
        returns (uint128 sharesIssued)
    {
        require(totalShares != 0 && modeLiquidity != 0, "ShareMath: not initialized");
        // depositLiquidity * totalShares / modeLiquidity, full-precision
        // intermediate to avoid overflow at large liquidity values.
        uint256 result = FullMath.mulDiv(depositLiquidity, totalShares, modeLiquidity);
        require(result <= type(uint128).max, "ShareMath: shares overflow");
        sharesIssued = uint128(result);
    }

    /// @notice Compute the liquidity to remove for a partial withdrawal.
    /// @param  shares           Shares being burned.
    /// @param  totalShares      Mode's total shares before burn.
    /// @param  modeLiquidity    Mode's current position liquidity.
    /// @return liquidityOut     Liquidity (v4 units) to remove from the mode.
    function liquidityForWithdraw(uint128 shares, uint128 totalShares, uint128 modeLiquidity)
        internal
        pure
        returns (uint128 liquidityOut)
    {
        require(totalShares != 0, "ShareMath: empty mode");
        require(shares <= totalShares, "ShareMath: shares > total");
        uint256 result = FullMath.mulDiv(shares, modeLiquidity, totalShares);
        // Bounded by modeLiquidity; safe to cast.
        liquidityOut = uint128(result);
    }

    /// @notice Update a mode's per-share fee accumulator after fees arrive.
    /// @param  prevCumulative Existing `feePerShareCumulative`.
    /// @param  feesAdded      Newly-collected fees (in token units).
    /// @param  totalShares    Mode's current total shares.
    /// @return newCumulative  Updated accumulator value.
    /// @dev    No-op when `totalShares == 0` — fees that arrive while a mode
    ///         is empty have nowhere to be attributed and would divide by
    ///         zero. Callers must ensure they don't drop fees in normal
    ///         operation (modes only collect fees when they hold liquidity,
    ///         which implies `totalShares > 0`).
    function accrueFeePerShare(uint256 prevCumulative, uint256 feesAdded, uint128 totalShares)
        internal
        pure
        returns (uint256 newCumulative)
    {
        if (totalShares == 0 || feesAdded == 0) return prevCumulative;
        // (feesAdded * Q128) / totalShares, full-precision intermediate.
        newCumulative = prevCumulative + FullMath.mulDiv(feesAdded, Q128, totalShares);
    }

    /// @notice Compute fees owed to a position given accumulator deltas.
    /// @param  shares                 Position's share count.
    /// @param  currentCumulative      Mode's current `feePerShareCumulative`.
    /// @param  snapshotCumulative     Position's `feeSnapshot` taken at last
    ///         deposit/update.
    /// @return feesOwed               Fees the position has earned since the
    ///         snapshot.
    /// @dev    Underflow guarded: a snapshot can never exceed the current
    ///         cumulative for a non-shrinking accumulator.
    function pendingFees(uint128 shares, uint256 currentCumulative, uint256 snapshotCumulative)
        internal
        pure
        returns (uint256 feesOwed)
    {
        if (shares == 0) return 0;
        require(currentCumulative >= snapshotCumulative, "ShareMath: snapshot > current");
        uint256 delta = currentCumulative - snapshotCumulative;
        feesOwed = FullMath.mulDiv(delta, shares, Q128);
    }
}
