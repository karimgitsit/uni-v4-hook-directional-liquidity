// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ModeRange
/// @notice Pure helpers for computing a mode's bin range from a reference
///         tick, and for evaluating the universal "should rebalance" trigger.
/// @dev    Bins are `binWidth × tickSpacing` ticks wide. Ranges are quantized
///         so `lower` is the largest multiple of `binWidth × tickSpacing`
///         strictly less than the reference tick (or equal to, depending on
///         alignment) — see `_floorBin`. The active bin is the one
///         containing the reference tick; mode positions sit in the bin
///         immediately on the appropriate side of it.
library ModeRange {
    /// @dev Mode-Right id; position one bin LEFT of price (single-sided
    ///      currency1 at deposit time).
    uint8 internal constant MODE_RIGHT = 0;
    /// @dev Mode-Left id; position one bin RIGHT of price (single-sided
    ///      currency0 at deposit time).
    uint8 internal constant MODE_LEFT = 1;
    /// @dev Mode-Both id; bidirectional — `bothShiftDir` selects side.
    uint8 internal constant MODE_BOTH = 2;

    /// @notice Floor `tick` to the nearest bin boundary at or below it.
    /// @param  tick      Reference tick (e.g. spot tick or TWAP tick).
    /// @param  binTicks  Bin width in ticks (`binWidth × tickSpacing`).
    /// @return lower     The lower bound of the bin that contains `tick`.
    /// @dev    Solidity's `/` truncates toward zero, so for negative ticks
    ///         we manually round toward negative infinity.
    function floorToBin(int24 tick, int24 binTicks) internal pure returns (int24 lower) {
        require(binTicks > 0, "ModeRange: binTicks=0");
        int24 q = tick / binTicks;
        int24 r = tick % binTicks;
        if (r < 0) q -= 1;
        lower = q * binTicks;
    }

    /// @notice The range of the bin that contains `tick`.
    /// @param tick     Reference tick.
    /// @param binTicks Bin width in ticks (`binWidth × tickSpacing`).
    /// @return lower   Lower bound of the bin (inclusive).
    /// @return upper   Upper bound of the bin (exclusive).
    function activeBin(int24 tick, int24 binTicks) internal pure returns (int24 lower, int24 upper) {
        lower = floorToBin(tick, binTicks);
        upper = lower + binTicks;
    }

    /// @notice Compute a mode's "one bin behind" position range relative to
    ///         a reference tick.
    /// @param  mode          0=Right, 1=Left, 2=Both.
    /// @param  tick          Reference tick (TWAP for rebalances, spot for
    ///         first-deposit init per spec §5.1).
    /// @param  binTicks      Bin width in ticks.
    /// @param  bothShiftDir  For Mode Both only: `false` means the position
    ///         sits to the LEFT of the active bin (last move was rightward);
    ///         `true` means it sits to the RIGHT (last move was leftward).
    ///         Ignored for Right/Left.
    /// @return lower         Lower tick of the mode's position.
    /// @return upper         Upper tick of the mode's position.
    function rangeForMode(uint8 mode, int24 tick, int24 binTicks, bool bothShiftDir)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        (int24 activeLower, int24 activeUpper) = activeBin(tick, binTicks);
        if (mode == MODE_RIGHT) {
            // Mode Right sits one bin LEFT of the active bin.
            upper = activeLower;
            lower = activeLower - binTicks;
        } else if (mode == MODE_LEFT) {
            // Mode Left sits one bin RIGHT of the active bin.
            lower = activeUpper;
            upper = activeUpper + binTicks;
        } else if (mode == MODE_BOTH) {
            // Mode Both: position sits behind the last move. `bothShiftDir`
            // tracks which side; same geometry as Right or Left.
            if (!bothShiftDir) {
                // Last move was rightward → position is to the left of price.
                upper = activeLower;
                lower = activeLower - binTicks;
            } else {
                lower = activeUpper;
                upper = activeUpper + binTicks;
            }
        } else {
            revert("ModeRange: bad mode");
        }
    }

    /// @notice Initial `lastShiftDir` for a fresh Mode-Both deposit.
    /// @dev    Spec §5.1.7: set on initial position placement. We default to
    ///         "position sits to the LEFT" (`false`), matching Mode-Right
    ///         geometry. Either choice is symmetric on first deposit since
    ///         no prior move exists; documenting the convention so it's
    ///         consistent with `rangeForMode`.
    function initialBothShiftDir() internal pure returns (bool) {
        return false;
    }

    /// @notice Compute the full next-shift target: whether to shift, the
    ///         resulting range, and (for Mode Both) the new shift direction.
    /// @dev    Spec §3 covers two trigger archetypes for Mode Both:
    ///         continuation (price keeps moving in the same direction the
    ///         position is reactive to) and reversal (price moves through
    ///         the position and out the other side). Mode Right and Mode
    ///         Left only have the continuation trigger by design.
    /// @return needsShift True if the mode should burn-and-remint.
    /// @return newLower   New lower tick (only meaningful when needsShift).
    /// @return newUpper   New upper tick.
    /// @return newDir     New `lastShiftDir` value (only Mode Both updates
    ///                    this; Right/Left return `currentDir`).
    function nextRebalanceTarget(
        uint8 mode,
        int24 twapTick,
        int24 rangeLower,
        int24 rangeUpper,
        int24 binTicks,
        bool currentDir
    ) internal pure returns (bool needsShift, int24 newLower, int24 newUpper, bool newDir) {
        newDir = currentDir;
        if (mode == MODE_RIGHT) {
            if (twapTick >= rangeUpper + binTicks) {
                needsShift = true;
                (newLower, newUpper) = rangeForMode(MODE_RIGHT, twapTick, binTicks, false);
            }
            return (needsShift, newLower, newUpper, false);
        }
        if (mode == MODE_LEFT) {
            if (twapTick < rangeLower - binTicks) {
                needsShift = true;
                (newLower, newUpper) = rangeForMode(MODE_LEFT, twapTick, binTicks, false);
            }
            return (needsShift, newLower, newUpper, false);
        }
        if (mode == MODE_BOTH) {
            if (!currentDir) {
                // Position left of price.
                if (twapTick >= rangeUpper + binTicks) {
                    needsShift = true; // continuation rightward
                    newDir = false;
                } else if (twapTick < rangeLower) {
                    needsShift = true; // reversal: TWAP exited position to the left
                    newDir = true;
                }
            } else {
                // Position right of price.
                if (twapTick < rangeLower - binTicks) {
                    needsShift = true; // continuation leftward
                    newDir = true;
                } else if (twapTick >= rangeUpper) {
                    needsShift = true; // reversal: TWAP exited position to the right
                    newDir = false;
                }
            }
            if (needsShift) {
                (newLower, newUpper) = rangeForMode(MODE_BOTH, twapTick, binTicks, newDir);
            }
            return (needsShift, newLower, newUpper, newDir);
        }
        revert("ModeRange: bad mode");
    }

    /// @notice Cheap "should this mode shift?" predicate. Identical to
    ///         `nextRebalanceTarget` but discards the new range and dir.
    /// @dev    Useful for off-chain keepers checking whether `rebalance()`
    ///         would do work without running the full geometry.
    /// @param mode         Mode id.
    /// @param twapTick     TWAP tick to evaluate against.
    /// @param rangeLower   Mode's current lower tick.
    /// @param rangeUpper   Mode's current upper tick.
    /// @param binTicks     Bin width in ticks.
    /// @param bothShiftDir Mode-Both's `lastShiftDir`; ignored otherwise.
    /// @return shouldShift True iff the mode would burn-and-remint now.
    function shouldRebalance(
        uint8 mode,
        int24 twapTick,
        int24 rangeLower,
        int24 rangeUpper,
        int24 binTicks,
        bool bothShiftDir
    ) internal pure returns (bool shouldShift) {
        (shouldShift,,,) = nextRebalanceTarget(mode, twapTick, rangeLower, rangeUpper, binTicks, bothShiftDir);
    }
}
