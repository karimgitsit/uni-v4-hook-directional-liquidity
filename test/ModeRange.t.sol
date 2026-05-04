// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ModeRange} from "../src/libraries/ModeRange.sol";

/// @dev Wrapper so `vm.expectRevert` sees a real call frame (library calls
///      are inlined into the test contract otherwise).
contract ModeRangeWrapper {
    function rangeForMode(uint8 mode, int24 tick, int24 binTicks, bool dir)
        external
        pure
        returns (int24, int24)
    {
        return ModeRange.rangeForMode(mode, tick, binTicks, dir);
    }
}

/// @title ModeRangeTest
/// @notice Pure-function tests for range geometry and shift triggers.
contract ModeRangeTest is Test {
    int24 constant BIN = 60; // binWidth * tickSpacing for these tests
    ModeRangeWrapper internal w;

    function setUp() public {
        w = new ModeRangeWrapper();
    }

    // ------------------------------------------------------------------ //
    // floorToBin                                                         //
    // ------------------------------------------------------------------ //

    function test_floor_zero() public pure {
        assertEq(int256(ModeRange.floorToBin(0, BIN)), int256(0));
    }

    function test_floor_alignedTickIsItself() public pure {
        assertEq(int256(ModeRange.floorToBin(120, BIN)), int256(120));
        assertEq(int256(ModeRange.floorToBin(-60, BIN)), int256(-60));
    }

    function test_floor_positiveRoundsDown() public pure {
        assertEq(int256(ModeRange.floorToBin(125, BIN)), int256(120));
        assertEq(int256(ModeRange.floorToBin(59, BIN)), int256(0));
    }

    /// Negative ticks must round toward -infinity, not toward zero.
    function test_floor_negativeRoundsTowardNegInfinity() public pure {
        // -1 / 60 truncates to 0 (Solidity), but the BIN containing -1 is
        // [-60, 0). So expected is -60.
        assertEq(int256(ModeRange.floorToBin(-1, BIN)), int256(-60));
        assertEq(int256(ModeRange.floorToBin(-61, BIN)), int256(-120));
    }

    // ------------------------------------------------------------------ //
    // rangeForMode                                                       //
    // ------------------------------------------------------------------ //

    function test_range_modeRightSitsLeftOfActive() public pure {
        // Active bin around tick 100: [60, 120). Mode Right = [0, 60).
        (int24 lower, int24 upper) = ModeRange.rangeForMode(ModeRange.MODE_RIGHT, 100, BIN, false);
        assertEq(int256(lower), int256(0));
        assertEq(int256(upper), int256(60));
    }

    function test_range_modeLeftSitsRightOfActive() public pure {
        // Active bin around tick 100: [60, 120). Mode Left = [120, 180).
        (int24 lower, int24 upper) = ModeRange.rangeForMode(ModeRange.MODE_LEFT, 100, BIN, false);
        assertEq(int256(lower), int256(120));
        assertEq(int256(upper), int256(180));
    }

    function test_range_modeBothFollowsShiftDir() public pure {
        // Active bin [60, 120). Both with shiftDir=false → left-of-price = [0, 60).
        (int24 lo0, int24 hi0) = ModeRange.rangeForMode(ModeRange.MODE_BOTH, 100, BIN, false);
        assertEq(int256(lo0), int256(0));
        assertEq(int256(hi0), int256(60));

        // Both with shiftDir=true → right-of-price = [120, 180).
        (int24 lo1, int24 hi1) = ModeRange.rangeForMode(ModeRange.MODE_BOTH, 100, BIN, true);
        assertEq(int256(lo1), int256(120));
        assertEq(int256(hi1), int256(180));
    }

    function test_range_revertsOnBadMode() public {
        vm.expectRevert(bytes("ModeRange: bad mode"));
        w.rangeForMode(99, 0, BIN, false);
    }

    // ------------------------------------------------------------------ //
    // shouldRebalance                                                    //
    // ------------------------------------------------------------------ //

    function test_trigger_modeRightFiresOnRightExit() public pure {
        // Mode Right at [0, 60). Active bin (the one ahead) = [60, 120).
        // Trigger when TWAP ≥ 120 (fully exited the active bin to the right).
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_RIGHT, 119, 0, 60, BIN, false));
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_RIGHT, 120, 0, 60, BIN, false));
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_RIGHT, 200, 0, 60, BIN, false));
    }

    function test_trigger_modeRightSilentOnLeftMove() public pure {
        // Mode Right is one-directional — leftward TWAP must not trigger it.
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_RIGHT, -120, 0, 60, BIN, false));
        // Even when TWAP is inside the position itself, no trigger.
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_RIGHT, 30, 0, 60, BIN, false));
    }

    function test_trigger_modeLeftFiresOnLeftExit() public pure {
        // Mode Left at [120, 180). Active bin (the one ahead, leftward) = [60, 120).
        // Trigger when TWAP < 60 (fully exited that bin to the left).
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_LEFT, 60, 120, 180, BIN, false));
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_LEFT, 59, 120, 180, BIN, false));
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_LEFT, -100, 120, 180, BIN, false));
    }

    function test_trigger_modeBoth_inBinDoesNotFire() public pure {
        // Spec §3: when TWAP enters the position's own bin (price reverses
        // through the position), no rebalance. Position [0, 60), shiftDir=false,
        // TWAP inside the position → silent.
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 30, 0, 60, BIN, false));
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 0, 0, 60, BIN, false));
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 59, 0, 60, BIN, false));
    }

    function test_trigger_modeBoth_fullReversalFires() public pure {
        // Position [0, 60), shiftDir=false (left of price). When TWAP fully
        // exits the position to the left (TWAP < 0), the position has been
        // swapped through and the mode should reconcentrate on the OTHER
        // side of the new (lower) price.
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, -1, 0, 60, BIN, false));
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, -200, 0, 60, BIN, false));

        // Mirror: position [120, 180), shiftDir=true. TWAP exits on the
        // right (≥ 180) → reversal fires.
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 180, 120, 180, BIN, true));
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 999, 120, 180, BIN, true));
    }

    // ------------------------------------------------------------------ //
    // nextRebalanceTarget                                                //
    // ------------------------------------------------------------------ //

    function test_nextTarget_modeRightContinuation() public pure {
        (bool shift, int24 lo, int24 hi, bool dir) =
            ModeRange.nextRebalanceTarget(ModeRange.MODE_RIGHT, 200, 0, 60, BIN, false);
        assertTrue(shift, "should shift");
        assertEq(int256(lo), int256(120));
        assertEq(int256(hi), int256(180));
        assertFalse(dir, "Right doesn't use dir");
    }

    function test_nextTarget_modeBothContinuationKeepsDir() public pure {
        // Position [0, 60), dir=false. TWAP=200 → continuation rightward.
        // New position one bin behind tick 200 = floor(200/60)=180. Active
        // bin [180, 240); position one bin left = [120, 180); dir stays false.
        (bool shift, int24 lo, int24 hi, bool dir) =
            ModeRange.nextRebalanceTarget(ModeRange.MODE_BOTH, 200, 0, 60, BIN, false);
        assertTrue(shift);
        assertEq(int256(lo), int256(120));
        assertEq(int256(hi), int256(180));
        assertFalse(dir, "continuation keeps dir");
    }

    function test_nextTarget_modeBothReversalFlipsDir() public pure {
        // Position [0, 60), dir=false. TWAP=-100 → reversal. Active bin
        // around -100 = [-120, -60); new position one bin RIGHT (dir=true)
        // = [-60, 0); dir flips to true.
        (bool shift, int24 lo, int24 hi, bool dir) =
            ModeRange.nextRebalanceTarget(ModeRange.MODE_BOTH, -100, 0, 60, BIN, false);
        assertTrue(shift);
        assertEq(int256(lo), int256(-60));
        assertEq(int256(hi), int256(0));
        assertTrue(dir, "reversal flips dir to right-of-price");
    }

    function test_nextTarget_noShiftWhenWithinPosition() public pure {
        (bool shift,,,) = ModeRange.nextRebalanceTarget(ModeRange.MODE_BOTH, 30, 0, 60, BIN, false);
        assertFalse(shift);
    }

    function test_trigger_modeBothFiresInReactiveDirection() public pure {
        // Position [0, 60), shiftDir=false (left-of-price). Reactive direction
        // is rightward — TWAP ≥ 120 fires.
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 120, 0, 60, BIN, false));

        // Position [120, 180), shiftDir=true (right-of-price). Reactive
        // direction is leftward — TWAP < 60 fires.
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 59, 120, 180, BIN, true));
        assertFalse(ModeRange.shouldRebalance(ModeRange.MODE_BOTH, 60, 120, 180, BIN, true));
    }

    /// Multi-bin TWAP jump: trigger still fires; new range will skip ahead
    /// (geometry computes the bin one behind current TWAP). Spec §3
    /// "multi-bin jumps" + §7.7.
    function test_trigger_multiBinJumpStillFires() public pure {
        // Mode Right at [0, 60); TWAP jumped to 1000.
        assertTrue(ModeRange.shouldRebalance(ModeRange.MODE_RIGHT, 1_000, 0, 60, BIN, false));
        // The new range, computed from the jumped tick, lands one bin
        // behind: floor(1000/60)*60 = 960; new Mode Right = [900, 960).
        (int24 lo, int24 hi) = ModeRange.rangeForMode(ModeRange.MODE_RIGHT, 1_000, BIN, false);
        assertEq(int256(lo), int256(900));
        assertEq(int256(hi), int256(960));
    }
}
