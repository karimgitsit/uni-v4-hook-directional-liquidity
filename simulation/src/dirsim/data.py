"""Subgraph fetch + parquet cache for Uniswap v3 swaps.

Real data path: query a Uniswap v3 subgraph for Swap entities in a time
window and persist to parquet. Configure with env var SUBGRAPH_URL — for
The Graph Network this looks like
  https://gateway.thegraph.com/api/<API_KEY>/subgraphs/id/<DEPLOYMENT_ID>

Fallback: if SUBGRAPH_URL is unset we synthesize a deterministic walk
over the requested window so the rest of the pipeline can be tested
without an API key. The synthetic path is clearly marked so it can never
be confused with real data downstream.
"""

from __future__ import annotations

import math
import os
import random
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import requests

from .pool import PoolInfo, BASE_USDC_ETH_005, price_to_tick


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


def _fetch_subgraph(spec: FetchSpec, page_size: int = 1000) -> pd.DataFrame:
    url = os.environ.get("SUBGRAPH_URL")
    if not url:
        raise RuntimeError(
            "SUBGRAPH_URL not set. Either export it (e.g. a Graph Network "
            "gateway URL with API key) or pass source='synthetic' to "
            "generate a fallback dataset for pipeline testing."
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
        new = [r for r in batch if r["id"] not in seen_ids]
        rows.extend(new)
        seen_ids.update(r["id"] for r in new)
        last_ts = int(batch[-1]["timestamp"])
        if last_ts == cursor_ts and len(batch) < page_size:
            break
        cursor_ts = last_ts
        if len(batch) < page_size:
            break
        time.sleep(0.1)  # be nice to the gateway
    return _normalize_subgraph_rows(rows, spec.pool)


def _fetch_pool_hours(spec: FetchSpec, page_size: int = 1000) -> pd.DataFrame:
    url = os.environ.get("SUBGRAPH_URL")
    if not url:
        raise RuntimeError("SUBGRAPH_URL not set")
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
        time.sleep(0.1)
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


def _synthesize(spec: FetchSpec, swaps_per_hour: int = 600, seed: int = 42) -> pd.DataFrame:
    """Deterministic geometric brownian motion over the window.

    Swaps are spaced uniformly. Tick is derived from a GBM in price space.
    Fee USD is set so a roughly constant pool TVL would yield realistic
    daily fee revenue. This is a fallback to exercise the simulator end
    to end without subgraph access — never use for real return numbers.
    """
    rng = random.Random(seed)
    duration = spec.end_ts - spec.start_ts
    n = max(1, (duration // 3600) * swaps_per_hour)
    dt = duration / n
    sigma = 0.6 / math.sqrt(365 * 24 * 3600)  # ~60% annualized vol
    log_price = math.log(2000.0)  # USDC per WETH starting near $2k
    rows = []
    block = 20_000_000
    for i in range(n):
        ts = spec.start_ts + int(i * dt)
        log_price += rng.gauss(0, sigma * math.sqrt(dt))
        price = math.exp(log_price)
        tick = price_to_tick(price, spec.pool)
        amount_usd = abs(rng.gauss(0, 8000.0))
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
    df["fee_token1_usd"] = df["amountUSD"].abs() * (spec.pool.fee_pips / 1_000_000.0)
    df["pool_liquidity"] = 5e16
    return df


def load_swaps(
    pool: PoolInfo = BASE_USDC_ETH_005,
    start: str = "2025-04-01",
    end: str = "2025-05-01",
    source: str | None = None,
    refresh: bool = False,
) -> pd.DataFrame:
    """Return swap events for the window, hitting cache when available.

    `source` is auto-resolved: 'subgraph' if SUBGRAPH_URL is set, else
    'synthetic'. Pass explicitly to override.
    """
    start_ts = int(datetime.fromisoformat(start).replace(tzinfo=timezone.utc).timestamp())
    end_ts = int(datetime.fromisoformat(end).replace(tzinfo=timezone.utc).timestamp())
    if source is None:
        source = "subgraph" if os.environ.get("SUBGRAPH_URL") else "synthetic"
    spec = FetchSpec(pool=pool, start_ts=start_ts, end_ts=end_ts, source=source)
    cache = spec.cache_path()
    if cache.exists() and not refresh:
        return pd.read_parquet(cache)
    if source == "subgraph":
        df = _fetch_subgraph(spec)
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
