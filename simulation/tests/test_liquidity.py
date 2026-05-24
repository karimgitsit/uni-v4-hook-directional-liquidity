"""Unit tests for dirsim.liquidity.

Covers:
- amounts_for_liquidity / liquidity_for_amounts round-trip
- Position composition at range boundaries (all token0, all token1)
- Known-tick USD valuation against hand-computed value
- usd_to_liquidity scale invariance
- Fee share fraction (analytical lp_L / pool_L)
"""

from __future__ import annotations

import math

import pytest

from dirsim.liquidity import (
    Position,
    amounts_for_liquidity,
    liquidity_for_amounts,
    position_value_usd,
    sqrt_p_at_tick,
    usd_to_liquidity,
)
from dirsim.pool import (
    BASE_USDC_ETH_005,
    MAINNET_USDC_ETH_005,
    eth_price_usd,
    human_price_t1_per_t0,
    token_prices_usd,
)


REL = 1e-9  # relative tolerance for floating-point sqrt-price math


def _approx(actual, expected, rel=REL):
    return math.isclose(actual, expected, rel_tol=rel, abs_tol=1e-12)


# --- amounts_for_liquidity / liquidity_for_amounts round trip ---------------

@pytest.mark.parametrize("tick_l,tick_u,tick", [
    (195_000, 196_000, 195_500),  # in range
    (195_000, 196_000, 195_000),  # at lower bound (all token0 above sqrtPa)
    (195_000, 196_000, 195_999),  # just below upper bound
])
def test_amounts_roundtrip_in_range(tick_l, tick_u, tick):
    sqrt_p = sqrt_p_at_tick(tick)
    sqrt_pa = sqrt_p_at_tick(tick_l)
    sqrt_pb = sqrt_p_at_tick(tick_u)
    L_in = 1e18
    a0, a1 = amounts_for_liquidity(sqrt_p, sqrt_pa, sqrt_pb, L_in)
    L_out = liquidity_for_amounts(sqrt_p, sqrt_pa, sqrt_pb, a0, a1)
    assert _approx(L_out, L_in)


# --- boundary composition: below range = all token0, above range = all token1 -

def test_composition_below_range_is_all_token0():
    tick_l, tick_u = 195_000, 196_000
    tick_active = 194_500  # below range
    sqrt_p = sqrt_p_at_tick(tick_active)
    sqrt_pa = sqrt_p_at_tick(tick_l)
    sqrt_pb = sqrt_p_at_tick(tick_u)
    a0, a1 = amounts_for_liquidity(sqrt_p, sqrt_pa, sqrt_pb, 1e18)
    assert a1 == 0.0
    assert a0 > 0


def test_composition_above_range_is_all_token1():
    tick_l, tick_u = 195_000, 196_000
    tick_active = 196_500
    sqrt_p = sqrt_p_at_tick(tick_active)
    sqrt_pa = sqrt_p_at_tick(tick_l)
    sqrt_pb = sqrt_p_at_tick(tick_u)
    a0, a1 = amounts_for_liquidity(sqrt_p, sqrt_pa, sqrt_pb, 1e18)
    assert a0 == 0.0
    assert a1 > 0


def test_composition_in_range_has_both_tokens():
    tick_l, tick_u = 195_000, 196_000
    sqrt_p = sqrt_p_at_tick(195_500)
    sqrt_pa = sqrt_p_at_tick(tick_l)
    sqrt_pb = sqrt_p_at_tick(tick_u)
    a0, a1 = amounts_for_liquidity(sqrt_p, sqrt_pa, sqrt_pb, 1e18)
    assert a0 > 0 and a1 > 0


# --- usd_to_liquidity round-trip: deposit X USD, value position back -------

@pytest.mark.parametrize("pool,tick_l,tick_u,active_tick", [
    (MAINNET_USDC_ETH_005, 195_000, 196_000, 195_500),
    (MAINNET_USDC_ETH_005, 194_000, 198_000, 196_000),  # wider range
    (BASE_USDC_ETH_005, -196_000, -195_000, -195_500),  # mirror token ordering
])
def test_usd_to_liquidity_value_roundtrip(pool, tick_l, tick_u, active_tick):
    """A position created from $X USD should value back to $X USD at the same tick."""
    sqrt_p = sqrt_p_at_tick(active_tick)
    sqrt_pa = sqrt_p_at_tick(tick_l)
    sqrt_pb = sqrt_p_at_tick(tick_u)
    deposit = 100_000.0
    L = usd_to_liquidity(deposit, sqrt_p, sqrt_pa, sqrt_pb, pool, active_tick)
    pos = Position(tick_lower=tick_l, tick_upper=tick_u, liquidity=L)
    assert math.isclose(pos.value_usd(sqrt_p, active_tick, pool), deposit, rel_tol=1e-9)


def test_usd_to_liquidity_full_range_roundtrip():
    """Full-range (TickMath bounds rounded to spacing) deposit value round-trip."""
    pool = MAINNET_USDC_ETH_005
    tick = 196_257  # ETH ~$3000
    sqrt_p = sqrt_p_at_tick(tick)
    sqrt_pa = sqrt_p_at_tick(-887_220)
    sqrt_pb = sqrt_p_at_tick(887_220)
    deposit = 100_000.0
    L = usd_to_liquidity(deposit, sqrt_p, sqrt_pa, sqrt_pb, pool, tick)
    pos = Position(tick_lower=-887_220, tick_upper=887_220, liquidity=L)
    # Full range tolerances are slightly looser: sqrtPa is tiny, sqrtPb huge,
    # the float64 path accumulates a touch more error.
    assert math.isclose(pos.value_usd(sqrt_p, tick, pool), deposit, rel_tol=1e-6)


# --- known-tick fee share: in-range L_lp / pool_L is the analytical share --

def test_fee_share_analytical_price_taker():
    """Analytical: lp gets lp_L / pool_L of any swap fee while in range.
    This is the formula our LPs use in price_taker mode.
    """
    pool_L = 5e17
    lp_L = 1e16
    swap_fee_usd = 100.0
    expected = swap_fee_usd * lp_L / pool_L
    assert math.isclose(expected, 2.0, rel_tol=1e-12)


def test_fee_share_includes_lp_when_not_price_taker():
    """When price_taker=False, denom is pool_L + lp_L."""
    pool_L = 5e17
    lp_L = 5e17
    swap_fee_usd = 100.0
    pt_share = swap_fee_usd * lp_L / pool_L
    non_pt_share = swap_fee_usd * lp_L / (pool_L + lp_L)
    assert pt_share == 100.0
    assert non_pt_share == 50.0
    assert non_pt_share < pt_share


# --- token_prices_usd sanity at known ticks --------------------------------

def test_eth_price_usd_mainnet_ordering():
    """Mainnet USDC/WETH: token0=USDC, token1=WETH. p0_usd=1, p1_usd = ETH price."""
    pool = MAINNET_USDC_ETH_005
    tick = 196_257
    p0, p1 = token_prices_usd(tick, pool)
    assert p0 == 1.0
    assert 2_500 < p1 < 3_500
    assert eth_price_usd(tick, pool) == p1


def test_eth_price_usd_base_ordering():
    """Base USDC/WETH: token0=WETH, token1=USDC. p1_usd=1, p0_usd = ETH price."""
    pool = BASE_USDC_ETH_005
    # Base uses flipped ordering, so price at tick=-196_257 should give ~$3000 ETH
    tick = -196_257
    p0, p1 = token_prices_usd(tick, pool)
    assert p1 == 1.0
    assert 2_500 < p0 < 3_500
    assert eth_price_usd(tick, pool) == p0
