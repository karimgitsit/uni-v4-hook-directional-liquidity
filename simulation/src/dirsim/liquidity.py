"""Uniswap v3 concentrated-liquidity math.

`P` here is the raw price token1/token0 in raw decimals, i.e.
`P = 1.0001 ** tick`. We work directly with `sqrt(P)` (a float) since
this simulator does not need uint160 fidelity — the on-chain contract
does, but a Python backtest is fine with float64 sqrt-prices.

USD valuation: callers pass the current tick and we look up per-token
USD prices via `token_prices_usd`, which handles either token ordering.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .pool import PoolInfo, token_prices_usd


def sqrt_p_at_tick(tick: int) -> float:
    return math.sqrt(1.0001) ** tick


def liquidity_for_amounts(
    sqrt_p: float, sqrt_pa: float, sqrt_pb: float, amount0: float, amount1: float
) -> float:
    """Maximum L mintable from (amount0, amount1) at current sqrt_p for
    range [sqrt_pa, sqrt_pb]. Mirrors v3-periphery LiquidityAmounts.
    """
    if sqrt_pa > sqrt_pb:
        sqrt_pa, sqrt_pb = sqrt_pb, sqrt_pa
    if sqrt_p <= sqrt_pa:
        return amount0 * (sqrt_pa * sqrt_pb) / (sqrt_pb - sqrt_pa)
    if sqrt_p < sqrt_pb:
        l0 = amount0 * (sqrt_p * sqrt_pb) / (sqrt_pb - sqrt_p)
        l1 = amount1 / (sqrt_p - sqrt_pa)
        return min(l0, l1)
    return amount1 / (sqrt_pb - sqrt_pa)


def amounts_for_liquidity(
    sqrt_p: float, sqrt_pa: float, sqrt_pb: float, liquidity: float
) -> tuple[float, float]:
    """Token0, token1 amounts (raw, in token decimals) for a position
    of size L at the current price. Inverse of liquidity_for_amounts.
    """
    if sqrt_pa > sqrt_pb:
        sqrt_pa, sqrt_pb = sqrt_pb, sqrt_pa
    if sqrt_p <= sqrt_pa:
        return liquidity * (sqrt_pb - sqrt_pa) / (sqrt_pa * sqrt_pb), 0.0
    if sqrt_p < sqrt_pb:
        amount0 = liquidity * (sqrt_pb - sqrt_p) / (sqrt_p * sqrt_pb)
        amount1 = liquidity * (sqrt_p - sqrt_pa)
        return amount0, amount1
    return 0.0, liquidity * (sqrt_pb - sqrt_pa)


def position_value_usd(
    amount0_raw: float, amount1_raw: float, tick: int, p: PoolInfo
) -> float:
    """Convert raw on-chain token amounts to USD via per-token prices."""
    p0_usd, p1_usd = token_prices_usd(tick, p)
    a0 = amount0_raw / (10 ** p.token0_decimals)
    a1 = amount1_raw / (10 ** p.token1_decimals)
    return a0 * p0_usd + a1 * p1_usd


def usd_to_liquidity(
    usd_value: float, sqrt_p: float, sqrt_pa: float, sqrt_pb: float, p: PoolInfo, tick: int
) -> float:
    """Compute L for a position whose mark-to-market value matches usd_value
    at the current price. We compute the implied (a0, a1) composition for
    L=1 from amounts_for_liquidity, value it in USD using both token prices,
    then scale.
    """
    if sqrt_pa > sqrt_pb:
        sqrt_pa, sqrt_pb = sqrt_pb, sqrt_pa
    a0_per_l, a1_per_l = amounts_for_liquidity(sqrt_p, sqrt_pa, sqrt_pb, 1.0)
    p0_usd, p1_usd = token_prices_usd(tick, p)
    usd_per_l = (
        a0_per_l / (10 ** p.token0_decimals) * p0_usd
        + a1_per_l / (10 ** p.token1_decimals) * p1_usd
    )
    if usd_per_l <= 0:
        return 0.0
    return usd_value / usd_per_l


@dataclass
class Position:
    tick_lower: int
    tick_upper: int
    liquidity: float       # L units (float64 — sim only)
    fee_usd: float = 0.0   # cumulative fees in USD

    @property
    def sqrt_pa(self) -> float:
        return sqrt_p_at_tick(self.tick_lower)

    @property
    def sqrt_pb(self) -> float:
        return sqrt_p_at_tick(self.tick_upper)

    def covers(self, tick: int) -> bool:
        return self.tick_lower <= tick < self.tick_upper

    def composition(self, sqrt_p: float) -> tuple[float, float]:
        return amounts_for_liquidity(sqrt_p, self.sqrt_pa, self.sqrt_pb, self.liquidity)

    def value_usd(self, sqrt_p: float, tick: int, p: PoolInfo) -> float:
        a0, a1 = self.composition(sqrt_p)
        return position_value_usd(a0, a1, tick, p)
