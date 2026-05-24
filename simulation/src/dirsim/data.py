"""Subgraph fetch + parquet cache for Uniswap v3 swaps.

Real data path: query a Uniswap v3 subgraph for Swap entities in a time
window and persist to parquet.

We support two ways to point at the right subgraph:

  - `SUBGRAPH_URL` env var — full gateway URL, takes precedence.
  - `GRAPH_API_KEY` env var — combined with the pool's
    `subgraph_deployment_id` to build the gateway URL.

Fallback: if neither is set we synthesize a deterministic walk over the
requested window so the rest of the pipeline can be tested without an
API key. The synthetic path is clearly marked so it can never be
confused with real data downstream.
"""

from __future__ import annotations

import math
import os
import random
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import pandas as pd
import requests

from .pool import PoolInfo, MAINNET_USDC_ETH_005, price_to_tick


CACHE_DIR = Path(__file__).resolve().parents[2] / ".cache"
CACHE_DIR.mkdir(exist_ok=True)


@dataclass(frozen=True)
class FetchSpec:
    pool: PoolInfo
    start_ts: int  # unix seconds (inclusive)
    end_ts: int    # unix seconds (exclusive)
    source: str    # "subgraph" or "synthetic"

    def cache_path(self) -> Path:
        return CACHE_DIR / (
            f"swaps_{self.pool.chain}_{self.pool.address.lower()}_"
            f"{self.start_ts}_{self.end_ts}_{self.source}.parquet"
        )


SWAPS_QUERY = """
query Swaps($pool: String!, $first: Int!, $lastTs: Int!, $endTs: Int!) {
  swaps(
    first: $first
    where: {pool: $pool, timestamp_gte: $lastTs, timestamp_lt: $endTs}
    orderBy: timestamp
    orderDirection: asc
  ) {
    id
    timestamp
    transaction { blockNumber }
    tick
    sqrtPriceX96
    amount0
    amount1
    amountUSD
  }
}
"""

POOL_HOUR_QUERY = """
query PoolHours($pool: String!, $first: Int!, $lastTs: Int!, $endTs: Int!) {
  poolHourDatas(
    first: $first
    where: {pool: $pool, periodStartUnix_gte: $lastTs, periodStartUnix_lt: $endTs}
    orderBy: periodStartUnix
    orderDirection: asc
  ) {
    periodStartUnix
    liquidity
    tick
    sqrtPrice
    tvlUSD
  }
}
"""


def _resolve_subgraph_url(p: PoolInfo) -> str | None:
    """Pick the subgraph URL for this pool. Explicit SUBGRAPH_URL wins;
    otherwise build one from GRAPH_API_KEY + the pool's deployment ID.
    """
    explicit = os.environ.get("SUBGRAPH_URL")
    if explicit:
        return explicit
    api_key = os.environ.get("GRAPH_API_KEY")
    if api_key and p.subgraph_deployment_id:
        return f"https://gateway.thegraph.com/api/{api_key}/subgraphs/id/{p.subgraph_deployment_id}"
    return None


def _fetch_subgraph(
    spec: FetchSpec,
    page_size: int = 1000,
    progress_callback: "Callable[[int], None] | None" = None,
) -> pd.DataFrame:
    url = _resolve_subgraph_url(spec.pool)
    if not url:
        raise RuntimeError(
            "No subgraph URL available. Either set SUBGRAPH_URL directly, "
            "or set GRAPH_API_KEY and let the pool's deployment ID supply "
            "the rest. Or pass source='synthetic' for a fallback dataset."
        )
    rows: list[dict] = []
    cursor_ts = spec.start_ts
    seen_ids: set[str] = set()
    while True:
        resp = requests.post(
            url,
            json={
                "query": SWAPS_QUERY,
                "variables": {
                    "pool": spec.pool.address.lower(),
                    "first": page_size,
                    "lastTs": cursor_ts,
                    "endTs": spec.end_ts,
                },
            },
            timeout=30,
        )
        resp.raise_for_status()
        payload = resp.json()
        if "errors" in payload:
            raise RuntimeError(f"Subgraph errors: {payload['errors']}")
        batch = payload["data"]["swaps"]
        if not batch:
            break
        prev_row_count = len(rows)
        new = [r for r in batch if r["id"] not in seen_ids]
        rows.extend(new)
        seen_ids.update(r["id"] for r in new)
        if progress_callback is not None:
            progress_callback(len(rows))
        # Safety: high-volume pools can put >page_size swaps at the same
        # timestamp. If a full page came back but we didn't actually add
        # any new rows, the cursor is stuck — bail rather than spin.
        if len(rows) == prev_row_count:
            break
        last_ts = int(batch[-1]["timestamp"])
        if last_ts == cursor_ts and len(batch) < page_size:
            break
        cursor_ts = last_ts
        if len(batch) < page_size:
            break
        time.sleep(0.02)  # be nice to the gateway
    return _normalize_subgraph_rows(rows, spec.pool)


def _fetch_pool_hours(spec: FetchSpec, page_size: int = 1000) -> pd.DataFrame:
    url = _resolve_subgraph_url(spec.pool)
    if not url:
        raise RuntimeError("No subgraph URL available (set SUBGRAPH_URL or GRAPH_API_KEY)")
    rows: list[dict] = []
    cursor_ts = spec.start_ts
    while True:
        resp = requests.post(
            url,
            json={
                "query": POOL_HOUR_QUERY,
                "variables": {
                    "pool": spec.pool.address.lower(),
                    "first": page_size,
                    "lastTs": cursor_ts,
                    "endTs": spec.end_ts,
                },
            },
            timeout=30,
        )
        resp.raise_for_status()
        payload = resp.json()
        if "errors" in payload:
            raise RuntimeError(f"Subgraph errors: {payload['errors']}")
        batch = payload["data"]["poolHourDatas"]
        if not batch:
            break
        rows.extend(batch)
        last_ts = int(batch[-1]["periodStartUnix"])
        if last_ts == cursor_ts and len(batch) < page_size:
            break
        cursor_ts = last_ts + 1
        if len(batch) < page_size:
            break
        time.sleep(0.02)
    if not rows:
        return pd.DataFrame(columns=["ts", "liquidity"])
    return pd.DataFrame(
        {
            "ts": [int(r["periodStartUnix"]) for r in rows],
            "liquidity": [float(int(r["liquidity"])) for r in rows],
        }
    ).drop_duplicates("ts").sort_values("ts").reset_index(drop=True)


def _attach_pool_liquidity(swaps: pd.DataFrame, hours: pd.DataFrame) -> pd.DataFrame:
    """Forward-fill the most recent hourly in-range liquidity onto each swap."""
    if swaps.empty:
        swaps["pool_liquidity"] = []
        return swaps
    if hours.empty:
        swaps["pool_liquidity"] = 0
        return swaps
    swaps_sorted = swaps.sort_values("ts").reset_index(drop=True)
    merged = pd.merge_asof(
        swaps_sorted, hours.sort_values("ts"), on="ts", direction="backward"
    )
    merged["pool_liquidity"] = merged["liquidity"].fillna(method="bfill").fillna(0.0).astype("float64")
    return merged.drop(columns=["liquidity"])


def _normalize_subgraph_rows(rows: list[dict], p: PoolInfo) -> pd.DataFrame:
    if not rows:
        return pd.DataFrame(
            columns=["ts", "block", "tick", "sqrtPriceX96", "amount0", "amount1", "amountUSD"]
        )
    df = pd.DataFrame(
        {
            "ts": [int(r["timestamp"]) for r in rows],
            "block": [int(r["transaction"]["blockNumber"]) for r in rows],
            "tick": [int(r["tick"]) for r in rows],
            "amount0": [float(r["amount0"]) for r in rows],
            "amount1": [float(r["amount1"]) for r in rows],
            "amountUSD": [float(r["amountUSD"]) for r in rows],
        }
    )
    df = df.drop_duplicates(subset=["ts", "block", "tick", "amount0"]).reset_index(drop=True)
    df["fee_token1_usd"] = df["amountUSD"].abs() * (p.fee_pips / 1_000_000.0)
    return df


def _synthesize(spec: FetchSpec, swaps_per_hour: int = 250, seed: int = 42) -> pd.DataFrame:
    """Deterministic geometric brownian motion over the window.

    Calibrated to roughly match Uniswap v3 USDC/WETH 0.05% Mainnet pool:
    ~$150-200M daily volume, ~5-10k swaps/day, in-range L on the order
    of 1e19. With the default knobs a $100k v3 ±20% LP earns low single
    digits %/month, which is roughly the real-pool ballpark for April 2025.

    Still a fallback — never publish real return numbers off this path.
    """
    rng = random.Random(seed)
    duration = spec.end_ts - spec.start_ts
    n = max(1, (duration // 3600) * swaps_per_hour)
    dt = duration / n
    sigma = 0.6 / math.sqrt(365 * 24 * 3600)  # ~60% annualized vol
    eth_price_in_usd = 2000.0
    # human_price_t1_per_t0: on token1=USDC pools this IS the ETH price;
    # on token0=USDC pools (Mainnet) it's the reciprocal.
    starting_hp = eth_price_in_usd if spec.pool.usd_token_index == 1 else 1.0 / eth_price_in_usd
    log_price = math.log(starting_hp)
    rows = []
    block = 20_000_000
    # Per-swap USD sigma. Real swap-size distribution is heavy-tailed; abs-gauss
    # is a crude model but adequate for a fallback. mean(|N(0,30k)|) ≈ $24k/swap.
    swap_usd_sigma = 30_000.0
    for i in range(n):
        ts = spec.start_ts + int(i * dt)
        log_price += rng.gauss(0, sigma * math.sqrt(dt))
        price = math.exp(log_price)
        tick = price_to_tick(price, spec.pool)
        amount_usd = abs(rng.gauss(0, swap_usd_sigma))
        side = rng.choice([-1, 1])
        amount0 = side * (amount_usd / price)
        amount1 = -side * amount_usd
        rows.append(
            dict(
                ts=ts,
                block=block + i // 4,
                tick=tick,
                amount0=amount0,
                amount1=amount1,
                amountUSD=amount_usd,
            )
        )
    df = pd.DataFrame(rows)
    # Column name kept for back-compat; value is always USD fees per swap.
    df["fee_token1_usd"] = df["amountUSD"].abs() * (spec.pool.fee_pips / 1_000_000.0)
    # Synthetic in-range pool L. Calibrated so that a $100k ±20% v3 LP
    # earns a realistic 1-3%/month from fees alone. Real pool L for USDC/WETH
    # 0.05% on Mainnet runs ~1e19 due to JIT bots concentrating near spot;
    # Base is roughly 1/4 of that.
    df["pool_liquidity"] = 2e19 if spec.pool.chain == "mainnet" else 5e18
    return df


def load_swaps(
    pool: PoolInfo = MAINNET_USDC_ETH_005,
    start: str = "2025-04-01",
    end: str = "2025-05-01",
    source: str | None = None,
    refresh: bool = False,
    progress_callback: "Callable[[int], None] | None" = None,
) -> pd.DataFrame:
    """Return swap events for the window, hitting cache when available.

    `source` is auto-resolved: 'subgraph' if a key/URL is available, else
    'synthetic'. Pass explicitly to override.
    """
    start_ts = int(datetime.fromisoformat(start).replace(tzinfo=timezone.utc).timestamp())
    end_ts = int(datetime.fromisoformat(end).replace(tzinfo=timezone.utc).timestamp())
    if source is None:
        source = "subgraph" if _resolve_subgraph_url(pool) else "synthetic"
    spec = FetchSpec(pool=pool, start_ts=start_ts, end_ts=end_ts, source=source)
    cache = spec.cache_path()
    if cache.exists() and not refresh:
        return pd.read_parquet(cache)
    if source == "subgraph":
        df = _fetch_subgraph(spec, progress_callback=progress_callback)
        hours = _fetch_pool_hours(spec)
        df = _attach_pool_liquidity(df, hours)
    elif source == "synthetic":
        df = _synthesize(spec)
    else:
        raise ValueError(f"unknown source: {source}")
    df.to_parquet(cache, index=False)
    return df


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--start", default="2025-04-01")
    ap.add_argument("--end", default="2025-05-01")
    ap.add_argument("--source", default=None, choices=[None, "subgraph", "synthetic"])
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()
    df = load_swaps(start=args.start, end=args.end, source=args.source, refresh=args.refresh)
    print(f"rows={len(df)} span={df['ts'].min()}..{df['ts'].max()}")
    print(df.head(3))
    print(df.tail(3))
