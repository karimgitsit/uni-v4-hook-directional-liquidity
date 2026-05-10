"""Uniswap v3 concentrated-liquidity math.

`P` here is the raw price token1/token0 in raw decimals, i.e.
`P = 1.0001 ** tick`. We work directly with `sqrt(P)` (a float) since
this simulator does not need uint160 fidelity — the on-chain contract
does, but a Python backtest is fine with float64 sqrt-prices.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .pool import PoolInfo


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
    amount0_raw: float, amount1_raw: float, price: float, p: PoolInfo
) -> float:
    """Convert raw on-chain token amounts to USD assuming token1 ($1)."""
    a0 = amount0_raw / (10 ** p.token0_decimals)
    a1 = amount1_raw / (10 ** p.token1_decimals)
    return a0 * price + a1


def usd_to_liquidity(
    usd_value: float, sqrt_p: float, sqrt_pa: float, sqrt_pb: float, p: PoolInfo, price: float
) -> float:
    """Compute L for a position whose mark-to-market value matches usd_value
    at the current price. We split deposit value into (amount0, amount1)
    proportional to whatever ratio the range demands at sqrt_p, then call
    liquidity_for_amounts.

    For an in-range position, the implied composition for L=1 is
    `((sqrt_pb - sqrt_p)/(sqrt_p*sqrt_pb), (sqrt_p - sqrt_pa))`. We scale
    so the USD value of those amounts equals usd_value.
    """
    if sqrt_pa > sqrt_pb:
        sqrt_pa, sqrt_pb = sqrt_pb, sqrt_pa
    a0_per_l, a1_per_l = amounts_for_liquidity(sqrt_p, sqrt_pa, sqrt_pb, 1.0)
    usd_per_l = (
        a0_per_l / (10 ** p.token0_decimals) * price
        + a1_per_l / (10 ** p.token1_decimals)
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

    def value_usd(self, sqrt_p: float, price: float, p: PoolInfo) -> float:
        a0, a1 = self.composition(sqrt_p)
        return position_value_usd(a0, a1, price, p)
