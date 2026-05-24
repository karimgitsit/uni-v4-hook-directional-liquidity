"""Static v3 LP — never rebalances. Range is set at deposit time
(width relative to the starting price) and held to the end.
"""

from __future__ import annotations

from dataclasses import dataclass

from ..liquidity import Position, sqrt_p_at_tick, usd_to_liquidity
from ..pool import PoolInfo
from .base import LP, SwapEvent


@dataclass
class V3StaticLP(LP):
    range_pct: float = 0.20   # ± fraction around start price; 0.20 = ±20%
    full_range: bool = False
    price_taker: bool = True

    def initialize(self, start_tick: int, start_sqrt_p: float) -> None:
        if self.full_range:
            tick_l = -887_220  # close to TickMath MIN/MAX, snapped to multiple of 60
            tick_u = 887_220
        else:
            # Convert ±range_pct in price space to tick offsets.
            import math
            tick_offset = int(round(math.log(1 + self.range_pct) / math.log(1.0001)))
            ts = self.pool.tick_spacing
            tick_l = (start_tick - tick_offset) // ts * ts
            tick_u = ((start_tick + tick_offset) + ts - 1) // ts * ts
        sqrt_pa = sqrt_p_at_tick(tick_l)
        sqrt_pb = sqrt_p_at_tick(tick_u)
        liq = usd_to_liquidity(self.deposit_usd, start_sqrt_p, sqrt_pa, sqrt_pb, self.pool, start_tick)
        self.position = Position(tick_lower=tick_l, tick_upper=tick_u, liquidity=liq)
        self.initial_value_usd = self.deposit_usd
        self.initial_amount0_raw, self.initial_amount1_raw = self.position.composition(start_sqrt_p)

    def on_swap(self, ev: SwapEvent) -> None:
        if self.position is None:
            return
        if not self.position.covers(ev.tick):
            return
        denom = ev.pool_liquidity if self.price_taker else ev.pool_liquidity + self.position.liquidity
        if denom <= 0:
            return
        share = self.position.liquidity / denom
        self.position.fee_usd += ev.fee_usd * share
