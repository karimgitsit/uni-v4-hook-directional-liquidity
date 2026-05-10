"""Hook engine: TWAP buffer, mode-shift trigger logic, keeper economics.

Mirrors spec §3-§5 in Python. The on-chain version keeps shares per-LP
because multiple LPs share one mode-pool; in this simulator each mode
has exactly one LP, so we omit share accounting and track L directly.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from enum import Enum


class Mode(Enum):
    RIGHT = "right"
    LEFT = "left"
    BOTH = "both"


class ShiftDir(Enum):
    RIGHT = 1   # position is left of price (price last moved right)
    LEFT = -1   # position is right of price (price last moved left)


@dataclass
class TwapBuffer:
    """Internal TWAP source. Mirrors spec §4: ring buffer populated
    from afterSwap. We store (ts, tick) pairs and compute time-weighted
    average over a window on demand.
    """

    window_seconds: int
    capacity: int = 256
    obs: deque = field(default_factory=deque)  # (ts, tick)

    def write(self, ts: int, tick: int) -> None:
        if self.obs and self.obs[-1][0] == ts:
            return  # one observation per second is enough
        self.obs.append((ts, tick))
        # keep enough history to span the window
        while len(self.obs) > 2 and self.obs[1][0] < ts - self.window_seconds:
            self.obs.popleft()
        while len(self.obs) > self.capacity:
            self.obs.popleft()

    def twap(self, now: int) -> int | None:
        """Return TWAP tick over [now - window, now], or None if cold."""
        if not self.obs:
            return None
        target_start = now - self.window_seconds
        # Walk through obs computing time-weighted average tick.
        weighted_sum = 0.0
        total_dt = 0.0
        prev_ts, prev_tick = self.obs[0]
        if prev_ts > target_start and len(self.obs) == 1:
            return prev_tick
        for ts, tick in list(self.obs)[1:]:
            seg_start = max(prev_ts, target_start)
            seg_end = min(ts, now)
            if seg_end > seg_start:
                weighted_sum += prev_tick * (seg_end - seg_start)
                total_dt += seg_end - seg_start
            prev_ts, prev_tick = ts, tick
        # Tail: from last observation up to now.
        seg_start = max(prev_ts, target_start)
        if now > seg_start:
            weighted_sum += prev_tick * (now - seg_start)
            total_dt += now - seg_start
        if total_dt <= 0:
            return prev_tick
        return int(weighted_sum / total_dt)


def active_bin(tick: int, bin_size_ticks: int) -> tuple[int, int]:
    """Bin-grid-aligned [lower, upper) containing tick."""
    lower = (tick // bin_size_ticks) * bin_size_ticks
    return lower, lower + bin_size_ticks


def initial_range(mode: Mode, tick: int, bin_size_ticks: int, dir_: ShiftDir = ShiftDir.RIGHT) -> tuple[int, int]:
    """Initial position placement at first deposit. Spec §5.1."""
    abl, abu = active_bin(tick, bin_size_ticks)
    if mode == Mode.RIGHT:
        return abl - bin_size_ticks, abl
    if mode == Mode.LEFT:
        return abu, abu + bin_size_ticks
    # Mode.BOTH — place using initial dir bias (default: same as Right)
    if dir_ == ShiftDir.RIGHT:
        return abl - bin_size_ticks, abl
    return abu, abu + bin_size_ticks


def shift_target(
    mode: Mode, twap_tick: int, bin_size_ticks: int, dir_: ShiftDir
) -> tuple[int, int, ShiftDir]:
    """Compute new range when a rebalance is triggered. Returns (lower,
    upper, new_dir). For Right/Left dir is fixed; for Both it reflects
    the direction the new position sits relative to price.
    """
    abl, abu = active_bin(twap_tick, bin_size_ticks)
    if mode == Mode.RIGHT:
        return abl - bin_size_ticks, abl, ShiftDir.RIGHT
    if mode == Mode.LEFT:
        return abu, abu + bin_size_ticks, ShiftDir.LEFT
    # Mode.BOTH — direction follows the new placement
    if dir_ == ShiftDir.RIGHT:
        return abl - bin_size_ticks, abl, ShiftDir.RIGHT
    return abu, abu + bin_size_ticks, ShiftDir.LEFT


def should_rebalance(
    mode: Mode,
    pos_lower: int,
    pos_upper: int,
    twap_tick: int,
    bin_size_ticks: int,
    dir_: ShiftDir,
) -> tuple[bool, ShiftDir]:
    """Universal rule (spec §3): a mode rebalances when TWAP exits the
    bin 'ahead of' the position in the mode's reactive direction. Returns
    (trigger, new_dir_for_mode_both).
    """
    if mode == Mode.RIGHT:
        ahead_upper = pos_upper + bin_size_ticks
        return twap_tick >= ahead_upper, ShiftDir.RIGHT
    if mode == Mode.LEFT:
        ahead_lower = pos_lower - bin_size_ticks
        return twap_tick < ahead_lower, ShiftDir.LEFT
    # Mode.BOTH: continuation OR reversal
    if dir_ == ShiftDir.RIGHT:
        # position is to the left of price; ahead is one bin to the right
        ahead_upper = pos_upper + bin_size_ticks
        if twap_tick >= ahead_upper:
            return True, ShiftDir.RIGHT      # continuation
        if twap_tick < pos_lower:
            return True, ShiftDir.LEFT       # reversal
        return False, dir_
    # dir_ == LEFT: position to the right of price; ahead is one bin left
    ahead_lower = pos_lower - bin_size_ticks
    if twap_tick < ahead_lower:
        return True, ShiftDir.LEFT
    if twap_tick >= pos_upper:
        return True, ShiftDir.RIGHT
    return False, dir_
