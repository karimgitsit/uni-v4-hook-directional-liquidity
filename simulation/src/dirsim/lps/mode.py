"""Mode LP — Right, Left, or Both. Single class parameterized by mode.

Wraps the hook engine in the LP interface used by the sim driver.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Optional

from ..hook import (
    Mode,
    ShiftDir,
    TwapBuffer,
    initial_range,
    shift_target,
    should_rebalance,
)
from ..liquidity import (
    Position,
    sqrt_p_at_tick,
    usd_to_liquidity,
    position_value_usd,
)
from .base import LP, SwapEvent


@dataclass
class ModeLP(LP):
    mode: Mode = Mode.RIGHT
    bin_width: int = 10            # multiples of tick_spacing
    twap_window: int = 600         # seconds
    keeper_reward_bps: int = 500   # 5%
    price_taker: bool = True
    gas_per_rebalance_usd: Callable[[float], float] = lambda price_eth_usd: 0.0
    initial_dir: ShiftDir = ShiftDir.RIGHT  # Mode Both only
    twap: TwapBuffer = field(init=False)
    dir_: ShiftDir = field(init=False)
    fees_since_last_rebalance: float = 0.0
    last_rebalance_ts: int = 0

    def __post_init__(self) -> None:
        self.twap = TwapBuffer(window_seconds=self.twap_window)
        self.dir_ = self.initial_dir

    @property
    def bin_size_ticks(self) -> int:
        return self.bin_width * self.pool.tick_spacing

    def initialize(self, start_tick: int, start_sqrt_p: float, start_price: float) -> None:
        lower, upper = initial_range(self.mode, start_tick, self.bin_size_ticks, self.dir_)
        sqrt_pa = sqrt_p_at_tick(lower)
        sqrt_pb = sqrt_p_at_tick(upper)
        liq = usd_to_liquidity(
            self.deposit_usd, start_sqrt_p, sqrt_pa, sqrt_pb, self.pool, start_price
        )
        self.position = Position(tick_lower=lower, tick_upper=upper, liquidity=liq)
        self.initial_value_usd = self.deposit_usd

    def on_swap(self, ev: SwapEvent) -> None:
        if self.position is not None and self.position.covers(ev.tick):
            denom = (
                ev.pool_liquidity
                if self.price_taker
                else ev.pool_liquidity + self.position.liquidity
            )
            if denom > 0:
                share = self.position.liquidity / denom
                fee = ev.fee_usd * share
                self.position.fee_usd += fee
                self.fees_since_last_rebalance += fee
        self.twap.write(ev.ts, ev.tick)

    def maybe_rebalance(self, ev: SwapEvent) -> None:
        if self.position is None:
            return
        twap_tick = self.twap.twap(ev.ts)
        if twap_tick is None:
            return
        triggered, new_dir = should_rebalance(
            self.mode,
            self.position.tick_lower,
            self.position.tick_upper,
            twap_tick,
            self.bin_size_ticks,
            self.dir_,
        )
        if not triggered:
            return
        new_lower, new_upper, _ = shift_target(
            self.mode, twap_tick, self.bin_size_ticks, new_dir
        )
        if new_lower == self.position.tick_lower and new_upper == self.position.tick_upper:
            return  # same-bin no-op (spec §5.5)
        # Keeper profitability gate: keeper only calls if reward > gas.
        keeper_reward = self.fees_since_last_rebalance * (self.keeper_reward_bps / 10_000.0)
        gas_cost = self.gas_per_rebalance_usd(ev.price)
        if keeper_reward < gas_cost:
            return  # opportunity skipped — position stays misaligned
        # Burn old position: get token composition at current price
        a0, a1 = self.position.composition(ev.sqrt_p)
        post_burn_value = position_value_usd(a0, a1, ev.price, self.pool)
        # Pay keeper from accrued fees (NOT from principal)
        self.position.fee_usd -= keeper_reward
        self.keeper_paid_usd += keeper_reward
        self.fees_since_last_rebalance = 0.0
        # Re-mint at new range, preserving post-burn principal value
        sqrt_pa = sqrt_p_at_tick(new_lower)
        sqrt_pb = sqrt_p_at_tick(new_upper)
        new_liq = usd_to_liquidity(
            post_burn_value, ev.sqrt_p, sqrt_pa, sqrt_pb, self.pool, ev.price
        )
        self.position = Position(
            tick_lower=new_lower,
            tick_upper=new_upper,
            liquidity=new_liq,
            fee_usd=self.position.fee_usd,
        )
        self.dir_ = new_dir
        self.rebalance_count += 1
        self.last_rebalance_ts = ev.ts
