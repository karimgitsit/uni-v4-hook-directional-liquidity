"""Tests for hook engine: TWAP buffer, shift triggers, first-deposit fallback.

Mirrors spec §4 (TWAP) and §5 (lifecycle) at the simulator level.
"""

from __future__ import annotations

import pytest

from dirsim.hook import (
    Mode,
    ShiftDir,
    TwapBuffer,
    active_bin,
    initial_range,
    shift_target,
    should_rebalance,
)
from dirsim.lps.mode import ModeLP
from dirsim.liquidity import sqrt_p_at_tick
from dirsim.lps.base import SwapEvent
from dirsim.pool import MAINNET_USDC_ETH_005


# --- TWAP buffer warmup (spec §4, §5.1) -----------------------------------

def test_twap_returns_none_when_empty():
    buf = TwapBuffer(window_seconds=600)
    assert buf.twap(now=1_000) is None


def test_twap_single_observation_returns_that_tick():
    """Spec §4: until two observations span twapWindow, TWAP returns the
    most recent observation's tick. Verifies the cold-buffer fallback."""
    buf = TwapBuffer(window_seconds=600)
    buf.write(ts=1_000, tick=195_500)
    assert buf.twap(now=1_000) == 195_500
    # Same tick even when called later — single point can't form an average.
    assert buf.twap(now=1_300) == 195_500


def test_twap_two_observations_returns_time_weighted_average():
    buf = TwapBuffer(window_seconds=1_500)  # window large enough to span both obs
    buf.write(ts=1_000, tick=195_000)
    buf.write(ts=1_300, tick=196_000)
    # At now=1_300: window=[-200, 1_300], first obs at 1_000 covers
    # [1_000, 1_300] = 300s @ 195_000. Tail seg_start = 1_300, now = 1_300 → no tail.
    # avg = 195_000.
    assert buf.twap(now=1_300) == 195_000
    # At now=2_200: window=[700, 2_200], both obs in window.
    #   seg [1_000, 1_300] = 300s @ 195_000 = 58_500_000
    #   tail [1_300, 2_200] = 900s @ 196_000 = 176_400_000
    #   total_dt = 1_200, weighted_sum = 234_900_000, avg = 195_750
    assert buf.twap(now=2_200) == 195_750


def test_twap_drops_segments_outside_window():
    """Once an observation falls outside the lookback window, its time
    weight goes to zero. Verifies the seg_start = max(prev_ts, target_start)
    clamp in TwapBuffer.twap (hook.py:60)."""
    buf = TwapBuffer(window_seconds=600)
    buf.write(ts=1_000, tick=195_000)
    buf.write(ts=1_300, tick=196_000)
    # At now=1_900: window=[1_300, 1_900], first obs falls out of window.
    # Only the tail at 196_000 contributes → avg = 196_000.
    assert buf.twap(now=1_900) == 196_000


def test_twap_buffer_drops_observations_older_than_window():
    buf = TwapBuffer(window_seconds=600)
    buf.write(ts=0, tick=100)
    buf.write(ts=1_000, tick=200)
    buf.write(ts=2_000, tick=300)
    # After three writes, the very first should be dropped since obs[1].ts
    # (1_000) is < ts - window (2_000 - 600 = 1_400)
    assert len(buf.obs) == 2
    assert buf.obs[0] == (1_000, 200)


def test_twap_collapses_same_timestamp_writes():
    buf = TwapBuffer(window_seconds=600)
    buf.write(ts=1_000, tick=100)
    buf.write(ts=1_000, tick=200)  # ignored: same ts
    assert len(buf.obs) == 1
    assert buf.obs[0] == (1_000, 100)


# --- First-deposit uses spot tick when buffer is cold (spec §5.1) ---------

def test_first_deposit_uses_spot_tick_not_twap():
    """Spec §5.1: 'Read pool's current tick (via extsload / StateLibrary)'.
    The sim's `initialize()` takes start_tick directly, mirroring spot-tick
    fallback. ModeLP must place the initial range against that spot tick,
    NOT block waiting for twap warmup.
    """
    lp = ModeLP(
        name="Mode Right",
        pool=MAINNET_USDC_ETH_005,
        deposit_usd=100_000.0,
        mode=Mode.RIGHT,
        bin_width=10,  # 10 × 10 tickSpacing = 100 ticks
    )
    start_tick = 195_500
    lp.initialize(start_tick, sqrt_p_at_tick(start_tick))
    # twap buffer is still cold; that's fine for initialization
    assert lp.twap.twap(now=0) is None
    assert lp.position is not None
    # Mode Right: position is one bin LEFT of active. active_bin for tick
    # 195_500 with size 100 = [195_500, 195_600). Position = [195_400, 195_500)
    assert lp.position.tick_lower == 195_400
    assert lp.position.tick_upper == 195_500


def test_maybe_rebalance_no_op_while_twap_cold():
    """A keeper call against a cold buffer must not crash or rebalance."""
    lp = ModeLP(
        name="Mode Right",
        pool=MAINNET_USDC_ETH_005,
        deposit_usd=100_000.0,
        mode=Mode.RIGHT,
        bin_width=10,
    )
    lp.initialize(195_500, sqrt_p_at_tick(195_500))
    ev = SwapEvent(
        ts=1_000,
        tick=195_500,
        sqrt_p=sqrt_p_at_tick(195_500),
        fee_usd=0.0,
        pool_liquidity=5e17,
        eth_price_usd=3_000.0,
    )
    # No on_swap yet — buffer is still empty. maybe_rebalance must no-op.
    lp.maybe_rebalance(ev)
    assert lp.rebalance_count == 0


def test_keeper_gate_skips_when_reward_below_gas():
    """Spec §5.4: rebalance is permissionless; the simulator models a
    rational keeper that only calls when reward (bps × accrued fees)
    exceeds gas. With zero fees and any positive gas, the gate must skip.
    """
    expensive_gas = lambda eth_usd: 100.0  # $100 to mock prohibitive gas
    lp = ModeLP(
        name="Mode Right",
        pool=MAINNET_USDC_ETH_005,
        deposit_usd=100_000.0,
        mode=Mode.RIGHT,
        bin_width=10,
        gas_per_rebalance_usd=expensive_gas,
        keeper_reward_bps=500,
    )
    lp.initialize(195_500, sqrt_p_at_tick(195_500))
    # Warm the TWAP buffer with two observations spanning the window so
    # twap_tick is well-defined.
    base_ts = 0
    for offset in (0, lp.twap_window + 1):
        ev = SwapEvent(
            ts=base_ts + offset,
            tick=195_700,  # past the trigger (active+1 bin to the right)
            sqrt_p=sqrt_p_at_tick(195_700),
            fee_usd=0.0,
            pool_liquidity=1e19,
            eth_price_usd=3_000.0,
        )
        lp.on_swap(ev)
    # Trigger should be tripped — TWAP at 195_700 is past pos_upper+bin (195_600).
    # But fees_since_last_rebalance is 0 → keeper_reward = 0 → gate blocks.
    trigger_ev = SwapEvent(
        ts=base_ts + lp.twap_window + 100,
        tick=195_700,
        sqrt_p=sqrt_p_at_tick(195_700),
        fee_usd=0.0,
        pool_liquidity=1e19,
        eth_price_usd=3_000.0,
    )
    lp.maybe_rebalance(trigger_ev)
    assert lp.rebalance_count == 0


def test_keeper_gate_fires_when_reward_above_gas():
    """Inverse of the previous: cheap gas + accrued fees → gate passes."""
    cheap_gas = lambda eth_usd: 0.01
    lp = ModeLP(
        name="Mode Right",
        pool=MAINNET_USDC_ETH_005,
        deposit_usd=100_000.0,
        mode=Mode.RIGHT,
        bin_width=10,
        gas_per_rebalance_usd=cheap_gas,
        keeper_reward_bps=500,
    )
    lp.initialize(195_500, sqrt_p_at_tick(195_500))
    for offset in (0, lp.twap_window + 1):
        ev = SwapEvent(
            ts=offset,
            tick=195_700,
            sqrt_p=sqrt_p_at_tick(195_700),
            fee_usd=0.0,
            pool_liquidity=1e19,
            eth_price_usd=3_000.0,
        )
        lp.on_swap(ev)
    # Inject a fee directly to ensure the gate's reward side is non-zero.
    lp.fees_since_last_rebalance = 100.0
    trigger_ev = SwapEvent(
        ts=lp.twap_window + 100,
        tick=195_700,
        sqrt_p=sqrt_p_at_tick(195_700),
        fee_usd=0.0,
        pool_liquidity=1e19,
        eth_price_usd=3_000.0,
    )
    lp.maybe_rebalance(trigger_ev)
    assert lp.rebalance_count == 1
    # Position should have shifted right by one bin: new active for tick 195_700
    # is [195_700, 195_800); one bin LEFT is [195_600, 195_700).
    assert lp.position.tick_lower == 195_600
    assert lp.position.tick_upper == 195_700


# --- Shift trigger universal rule (spec §3) -------------------------------

def test_mode_right_triggers_on_rightward_twap_exit():
    bin_size = 100
    # Position at [195_400, 195_500). Active bin ahead = [195_500, 195_600)
    # Trigger fires when TWAP >= 195_600 (exits the bin ahead going right).
    triggered, _ = should_rebalance(Mode.RIGHT, 195_400, 195_500, 195_599, bin_size, ShiftDir.RIGHT)
    assert not triggered
    triggered, _ = should_rebalance(Mode.RIGHT, 195_400, 195_500, 195_600, bin_size, ShiftDir.RIGHT)
    assert triggered


def test_mode_left_triggers_on_leftward_twap_exit():
    bin_size = 100
    # Position at [195_500, 195_600). Bin ahead = [195_400, 195_500).
    # Trigger fires when TWAP < 195_400.
    triggered, _ = should_rebalance(Mode.LEFT, 195_500, 195_600, 195_400, bin_size, ShiftDir.LEFT)
    assert not triggered
    triggered, _ = should_rebalance(Mode.LEFT, 195_500, 195_600, 195_399, bin_size, ShiftDir.LEFT)
    assert triggered


def test_mode_both_continuation_and_reversal():
    """Spec §3 Mode Both:
    - dir=RIGHT, position left of price → continuation when TWAP exits to right
    - dir=RIGHT, reversal when TWAP < pos_lower (price swept through entirely)
    """
    bin_size = 100
    # Position at [195_400, 195_500), dir=RIGHT (we last shifted right)
    # Continuation: TWAP >= 195_600 (one bin past pos_upper)
    triggered, new_dir = should_rebalance(Mode.BOTH, 195_400, 195_500, 195_600, bin_size, ShiftDir.RIGHT)
    assert triggered and new_dir == ShiftDir.RIGHT
    # Reversal: TWAP < pos_lower means price swept all the way through and below
    triggered, new_dir = should_rebalance(Mode.BOTH, 195_400, 195_500, 195_399, bin_size, ShiftDir.RIGHT)
    assert triggered and new_dir == ShiftDir.LEFT
    # Within range or moderately reverted — no trigger
    triggered, _ = should_rebalance(Mode.BOTH, 195_400, 195_500, 195_450, bin_size, ShiftDir.RIGHT)
    assert not triggered


def test_initial_range_placement_matches_spec():
    """Spec §3 geometry table:
    - Right: one bin LEFT of active
    - Left: one bin RIGHT of active
    """
    bin_size = 100
    tick = 195_500
    lo, hi = initial_range(Mode.RIGHT, tick, bin_size)
    assert (lo, hi) == (195_400, 195_500)
    lo, hi = initial_range(Mode.LEFT, tick, bin_size)
    assert (lo, hi) == (195_600, 195_700)


def test_shift_target_consistent_with_should_rebalance():
    """When should_rebalance fires, shift_target produces a one-bin-behind
    placement against the current TWAP (spec §3 multi-bin TWAP jumps clause).
    """
    bin_size = 100
    twap = 198_750  # jumped multiple bins
    lo, hi, new_dir = shift_target(Mode.RIGHT, twap, bin_size, ShiftDir.RIGHT)
    # active bin for 198_750 = [198_700, 198_800); one bin LEFT = [198_600, 198_700)
    assert (lo, hi) == (198_600, 198_700)
    assert new_dir == ShiftDir.RIGHT
