"""End-to-end simulation driver.

Walks the event stream, drives the four LPs, returns a per-LP summary
plus a tidy time series for plotting.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

import math

import pandas as pd

from .data import load_swaps
from .hook import Mode
from .liquidity import sqrt_p_at_tick
from .lps.base import LP, SwapEvent
from .lps.mode import ModeLP
from .lps.v3 import V3StaticLP
from .pool import PoolInfo, MAINNET_USDC_ETH_005, eth_price_usd
from .presets import NETWORK_DEFAULTS, gas_fn


@dataclass
class SimConfig:
    deposit_usd: float = 100_000.0
    bin_width: int = 10
    twap_window: int = 600
    keeper_reward_bps: int = 500
    network_tier: str = "Layer 2"          # "Layer 1" | "Layer 2" | "Custom"
    gas_fee_gwei: float | None = None      # if None, take the tier default
    v3_range: str = "20pct"   # "5pct" | "20pct" | "full"
    price_taker: bool = True
    snapshot_every_seconds: int = 3600   # 1 hour

    def resolved_gwei(self) -> float:
        if self.gas_fee_gwei is not None:
            return self.gas_fee_gwei
        return NETWORK_DEFAULTS.get(self.network_tier, 0.05)

    def v3_range_pct(self) -> tuple[float, bool]:
        if self.v3_range == "5pct":
            return 0.05, False
        if self.v3_range == "20pct":
            return 0.20, False
        if self.v3_range == "full":
            return 0.0, True
        raise ValueError(self.v3_range)


@dataclass
class LPRow:
    name: str
    initial_usd: float
    final_value_usd: float
    fees_usd: float
    keeper_paid_usd: float
    rebalance_count: int

    @property
    def return_pct(self) -> float:
        return (self.final_value_usd / self.initial_usd - 1.0) * 100.0

    @property
    def il_usd(self) -> float:
        # principal value vs original deposit (how much position drift cost us)
        return (self.final_value_usd - self.fees_usd) - self.initial_usd


@dataclass
class SimResult:
    config: SimConfig
    summary: list[LPRow]
    timeseries: pd.DataFrame   # ts, lp_name, value_usd, fees_usd, principal_usd, price
    rebalances: pd.DataFrame   # ts, lp_name, price (one row per rebalance)


def run_sim(
    cfg: SimConfig,
    pool: PoolInfo = MAINNET_USDC_ETH_005,
    start: str = "2025-04-01",
    end: str = "2025-05-01",
    swaps: pd.DataFrame | None = None,
) -> SimResult:
    if swaps is None:
        swaps = load_swaps(pool=pool, start=start, end=end)
    if swaps.empty:
        raise RuntimeError("no swap data; check SUBGRAPH_URL or use synthetic source")

    # Initial state from first swap
    swaps = swaps.sort_values("ts").reset_index(drop=True)
    first = swaps.iloc[0]
    start_tick = int(first["tick"])
    start_sqrt_p = sqrt_p_at_tick(start_tick)

    range_pct, full_range = cfg.v3_range_pct()
    gas_callable = gas_fn(cfg.resolved_gwei())

    lps: list[LP] = [
        V3StaticLP(
            name=f"v3 baseline ({cfg.v3_range})",
            pool=pool,
            deposit_usd=cfg.deposit_usd,
            range_pct=range_pct,
            full_range=full_range,
            price_taker=cfg.price_taker,
        ),
        ModeLP(
            name="Mode Right",
            pool=pool,
            deposit_usd=cfg.deposit_usd,
            mode=Mode.RIGHT,
            bin_width=cfg.bin_width,
            twap_window=cfg.twap_window,
            keeper_reward_bps=cfg.keeper_reward_bps,
            price_taker=cfg.price_taker,
            gas_per_rebalance_usd=gas_callable,
        ),
        ModeLP(
            name="Mode Left",
            pool=pool,
            deposit_usd=cfg.deposit_usd,
            mode=Mode.LEFT,
            bin_width=cfg.bin_width,
            twap_window=cfg.twap_window,
            keeper_reward_bps=cfg.keeper_reward_bps,
            price_taker=cfg.price_taker,
            gas_per_rebalance_usd=gas_callable,
        ),
        ModeLP(
            name="Mode Both",
            pool=pool,
            deposit_usd=cfg.deposit_usd,
            mode=Mode.BOTH,
            bin_width=cfg.bin_width,
            twap_window=cfg.twap_window,
            keeper_reward_bps=cfg.keeper_reward_bps,
            price_taker=cfg.price_taker,
            gas_per_rebalance_usd=gas_callable,
        ),
    ]
    for lp in lps:
        lp.initialize(start_tick, start_sqrt_p)  # type: ignore[attr-defined]

    snapshot_rows: list[dict] = []
    rebal_rows: list[dict] = []
    last_snapshot = 0
    # Track per-LP rebalance counts seen at previous step so we can detect
    # new rebalances triggered inside maybe_rebalance() and stamp the event
    # with the swap's ts/price for the rebalance-marker visualization.
    prev_rebal_counts = [0] * len(lps)
    ticks = swaps["tick"].to_numpy()
    tss = swaps["ts"].to_numpy()
    fees = swaps["fee_token1_usd"].to_numpy()
    pool_liqs = swaps["pool_liquidity"].to_numpy()

    for i in range(len(swaps)):
        tick = int(ticks[i])
        ts = int(tss[i])
        sqrt_p = sqrt_p_at_tick(tick)
        eth_usd = eth_price_usd(tick, pool)
        ev = SwapEvent(
            ts=ts,
            tick=tick,
            sqrt_p=sqrt_p,
            fee_usd=float(fees[i]),
            pool_liquidity=float(pool_liqs[i]),
            eth_price_usd=eth_usd,
        )
        for idx, lp in enumerate(lps):
            lp.on_swap(ev)
            lp.maybe_rebalance(ev)
            if lp.rebalance_count > prev_rebal_counts[idx]:
                rebal_rows.append(dict(ts=ts, lp_name=lp.name, price=eth_usd))
                prev_rebal_counts[idx] = lp.rebalance_count
        if ts - last_snapshot >= cfg.snapshot_every_seconds:
            for lp in lps:
                fees_usd = lp.position.fee_usd if lp.position else 0.0
                total_val = lp.value_usd(sqrt_p, tick)
                principal_val = total_val - fees_usd
                snapshot_rows.append(
                    dict(
                        ts=ts,
                        lp_name=lp.name,
                        value_usd=total_val,
                        fees_usd=fees_usd,
                        principal_usd=principal_val,
                        price=eth_usd,
                    )
                )
            last_snapshot = ts

    # Final snapshot
    last = swaps.iloc[-1]
    final_tick = int(last["tick"])
    final_sqrt_p = sqrt_p_at_tick(final_tick)

    summary = []
    for lp in lps:
        final_val = lp.value_usd(final_sqrt_p, final_tick)
        fees_usd = lp.position.fee_usd if lp.position else 0.0
        summary.append(
            LPRow(
                name=lp.name,
                initial_usd=lp.initial_value_usd,
                final_value_usd=final_val,
                fees_usd=fees_usd,
                keeper_paid_usd=lp.keeper_paid_usd,
                rebalance_count=lp.rebalance_count,
            )
        )

    ts_df = pd.DataFrame(snapshot_rows)
    rb_df = pd.DataFrame(rebal_rows) if rebal_rows else pd.DataFrame(columns=["ts", "lp_name", "price"])
    return SimResult(config=cfg, summary=summary, timeseries=ts_df, rebalances=rb_df)


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--start", default="2025-04-01")
    ap.add_argument("--end", default="2025-05-01")
    ap.add_argument("--bin-width", type=int, default=10)
    ap.add_argument("--twap-window", type=int, default=600)
    ap.add_argument("--keeper-bps", type=int, default=500)
    ap.add_argument("--network", default="Layer 2", choices=["Layer 1", "Layer 2", "Custom"])
    ap.add_argument("--gwei", type=float, default=None,
                    help="Override gas price in gwei (required for --network Custom)")
    ap.add_argument("--v3-range", default="20pct", choices=["5pct", "20pct", "full"])
    args = ap.parse_args()

    cfg = SimConfig(
        bin_width=args.bin_width,
        twap_window=args.twap_window,
        keeper_reward_bps=args.keeper_bps,
        network_tier=args.network,
        gas_fee_gwei=args.gwei,
        v3_range=args.v3_range,
    )
    res = run_sim(cfg, start=args.start, end=args.end)
    print(f"\nConfig: {cfg}\n")
    print(f"{'LP':<28} {'final$':>12} {'return%':>10} {'fees$':>10} {'keeper$':>10} {'#rebal':>8}")
    print("-" * 84)
    for r in res.summary:
        print(
            f"{r.name:<28} {r.final_value_usd:>12,.0f} {r.return_pct:>10.2f} "
            f"{r.fees_usd:>10,.0f} {r.keeper_paid_usd:>10,.0f} {r.rebalance_count:>8}"
        )
