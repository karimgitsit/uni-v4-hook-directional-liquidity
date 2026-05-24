"""Pool constants and token-ordering helpers.

Two pools are supported:

  BASE_USDC_ETH_005   — Base, token0=WETH, token1=USDC
  MAINNET_USDC_ETH_005 — Mainnet, token0=USDC, token1=WETH  (order flipped)

`usd_token_index` records which side is the USD-pegged token so the
sim's USD-valuation math works for either ordering.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class PoolInfo:
    chain: str
    address: str
    fee_pips: int
    tick_spacing: int
    token0_symbol: str
    token0_decimals: int
    token1_symbol: str
    token1_decimals: int
    usd_token_index: int       # 0 or 1 — which side is USD-pegged
    subgraph_deployment_id: str  # canonical Uniswap v3 subgraph for this chain


MAINNET_USDC_ETH_005 = PoolInfo(
    chain="mainnet",
    address="0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640",
    fee_pips=500,
    tick_spacing=10,
    token0_symbol="USDC",
    token0_decimals=6,
    token1_symbol="WETH",
    token1_decimals=18,
    usd_token_index=0,
    subgraph_deployment_id="5zvR82QoaXYFyDEKLZ9t6v9adgnptxYpKpSbxtgVENFV",
)

BASE_USDC_ETH_005 = PoolInfo(
    chain="base",
    address="0xd0b53D9277642d899DF5C87A3966A349A798F224",
    fee_pips=500,
    tick_spacing=10,
    token0_symbol="WETH",
    token0_decimals=18,
    token1_symbol="USDC",
    token1_decimals=6,
    usd_token_index=1,
    subgraph_deployment_id="43Hwfi3dJSoGpyas9VwNoDAv55yjgGrPpNSmbQZArzMG",
)


def human_price_t1_per_t0(tick: int, p: PoolInfo) -> float:
    """`token1` human units per 1 `token0` human unit at the given tick.

    On Base this is USDC/WETH (≈ 2000). On Mainnet it's WETH/USDC (≈ 0.0005).
    Use `token_prices_usd` if you actually want USD values.
    """
    raw = 1.0001 ** tick
    return raw * (10 ** p.token0_decimals) / (10 ** p.token1_decimals)


def token_prices_usd(tick: int, p: PoolInfo) -> tuple[float, float]:
    """Return (USD per 1 human-unit token0, USD per 1 human-unit token1)."""
    hp = human_price_t1_per_t0(tick, p)
    if p.usd_token_index == 1:
        # token1 is USDC (=1), token0 is WETH, priced as hp USD per WETH
        return hp, 1.0
    # token0 is USDC (=1), token1 is WETH, priced as 1/hp USD per WETH
    if hp <= 0:
        return 1.0, 0.0
    return 1.0, 1.0 / hp


def eth_price_usd(tick: int, p: PoolInfo) -> float:
    """USD price of 1 ETH at the given tick. Looks up whichever side is
    WETH and returns its USD price. Used by gas-cost conversion.
    """
    p0, p1 = token_prices_usd(tick, p)
    return p1 if p.usd_token_index == 0 else p0


def price_to_tick(price_token1_per_token0: float, p: PoolInfo) -> int:
    """Inverse of human_price_t1_per_t0, snapped to int tick."""
    raw = price_token1_per_token0 * (10 ** p.token1_decimals) / (10 ** p.token0_decimals)
    return int(math.log(raw) / math.log(1.0001))
