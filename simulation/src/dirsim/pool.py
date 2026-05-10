"""Pool constants for the USDC/ETH 0.05% pool on Base.

Token ordering note: on Base, WETH (0x4200…0006) sorts before USDC
(0x8335…2913), so token0 = WETH, token1 = USDC. Price = token1/token0
= USDC per WETH, and tick increases as ETH appreciates in USD terms.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class PoolInfo:
    chain: str
    address: str
    fee_pips: int           # v3 fee in hundredths of a bip (500 = 0.05%)
    tick_spacing: int
    token0_symbol: str
    token0_decimals: int
    token1_symbol: str
    token1_decimals: int


BASE_USDC_ETH_005 = PoolInfo(
    chain="base",
    address="0xd0b53D9277642d899DF5C87A3966A349A798F224",
    fee_pips=500,
    tick_spacing=10,
    token0_symbol="WETH",
    token0_decimals=18,
    token1_symbol="USDC",
    token1_decimals=6,
)


def tick_to_price_token1_per_token0(tick: int, p: PoolInfo) -> float:
    """Human-readable price: token1 units per 1 token0 (USDC per WETH)."""
    raw = 1.0001 ** tick
    return raw * (10 ** p.token0_decimals) / (10 ** p.token1_decimals)


def price_to_tick(price_token1_per_token0: float, p: PoolInfo) -> int:
    """Inverse of tick_to_price_token1_per_token0, snapped to int tick."""
    import math
    raw = price_token1_per_token0 * (10 ** p.token1_decimals) / (10 ** p.token0_decimals)
    return int(math.log(raw) / math.log(1.0001))
