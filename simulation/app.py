"""Streamlit calculator for the Directional Liquidity Hook backtest.

Run from the simulation/ directory:

    PYTHONPATH=src streamlit run app.py

Set SUBGRAPH_URL to use real Uniswap v3 Base data; otherwise the app
falls back to a synthetic GBM dataset (clearly labeled).
"""

from __future__ import annotations

import os
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# Make `src/` importable so this works under either start mode:
#   - local:           PYTHONPATH=src streamlit run app.py
#   - Streamlit Cloud: streamlit run simulation/app.py  (no PYTHONPATH)
_SRC = Path(__file__).parent / "src"
if _SRC.is_dir() and str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

import pandas as pd

# Streamlit's plotly_chart emits a deprecation banner above every chart
# when it can't see an explicit `config` argument. Passing config={…}
# at each call site below opts into the new API and silences it cleanly.
PLOTLY_CONFIG = {"displaylogo": False}

# Load simulation/.env if present (no python-dotenv dependency).
_envfile = Path(__file__).with_name(".env")
if _envfile.exists():
    for line in _envfile.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st

# On Streamlit Cloud, secrets configured in the dashboard arrive via
# st.secrets — promote them to env vars so the rest of the app's
# env-based config (data.py reads SUBGRAPH_URL / GRAPH_API_KEY) still
# works unchanged.
try:
    for _k in ("SUBGRAPH_URL", "GRAPH_API_KEY"):
        if _k not in os.environ:
            _v = st.secrets.get(_k) if hasattr(st, "secrets") else None
            if _v:
                os.environ[_k] = str(_v)
except (FileNotFoundError, AttributeError):
    pass

from dirsim.data import load_swaps
from dirsim.pool import MAINNET_USDC_ETH_005
from dirsim.presets import NETWORK_DEFAULTS
from dirsim.sim import SimConfig, run_sim


@st.cache_data(show_spinner=False, ttl=60 * 60 * 24)
def cached_load_swaps(start_iso: str, end_iso: str) -> pd.DataFrame:
    """In-process cache on top of data.py's parquet cache.

    The parquet cache survives across reruns of the same window; this
    additionally avoids the parquet read on every re-render within a
    session, and lets us show a clean spinner around the *first* fetch.
    """
    return load_swaps(pool=MAINNET_USDC_ETH_005, start=start_iso, end=end_iso)


# Available historical window. The subgraph cache holds about a year of
# USDC/WETH 0.05% Mainnet swap data; default the picker to the most
# recent full month so first-time loads are fast.
DATA_MIN_DATE = date.today() - timedelta(days=365)
DATA_MAX_DATE = date.today()
DEFAULT_START = DATA_MAX_DATE - timedelta(days=30)
DEFAULT_END = DATA_MAX_DATE

st.set_page_config(page_title="Directional Liquidity Hook — Backtest", layout="wide")

_has_subgraph = bool(os.environ.get("SUBGRAPH_URL") or os.environ.get("GRAPH_API_KEY"))
source_label = (
    "Real subgraph data"
    if _has_subgraph
    else "⚠ Synthetic data — set GRAPH_API_KEY in simulation/.env for real Mainnet data"
)

with st.sidebar:
    st.header("Hook parameters")
    bin_width = st.slider("binWidth (× tickSpacing)", min_value=1, max_value=50, value=10, step=1,
                          help="Width of each mode's single-bin position. tickSpacing=10 for the 0.05% pool.")
    twap_window = st.slider("twapWindow (seconds)", min_value=60, max_value=3600, value=600, step=60,
                            help="Window over which the rebalance trigger averages tick.")
    keeper_bps = st.slider("Keeper reward (bps of fees)", min_value=0, max_value=2000, value=500, step=50,
                           help="% of fees per rebalance paid to whoever calls it. Spec default 500 (5%).")

    st.header("Backtest window")
    window = st.date_input(
        "Date range",
        value=(DEFAULT_START, DEFAULT_END),
        min_value=DATA_MIN_DATE,
        max_value=DATA_MAX_DATE,
        help="Pick any window inside the past year. Longer windows take longer to simulate.",
    )
    if isinstance(window, tuple) and len(window) == 2:
        start_date, end_date = window
    else:
        start_date, end_date = DEFAULT_START, DEFAULT_END

    st.header("Environment")
    network_tier = st.selectbox(
        "Network",
        ["Layer 1", "Layer 2", "Custom"],
        index=1,
        help="Sets gas-per-rebalance cost (200k gas × gwei × ETH price). "
             "Layer 1 ≈ Mainnet, Layer 2 ≈ Base/Optimism. Pick Custom to enter your own gwei.",
    )
    if network_tier == "Custom":
        gas_fee_gwei = st.number_input(
            "Gas price (gwei)",
            min_value=0.0,
            max_value=1000.0,
            value=1.0,
            step=0.01,
            format="%.4f",
        )
    else:
        default_gwei = NETWORK_DEFAULTS[network_tier]
        st.caption(f"Using {default_gwei} gwei (default for {network_tier}).")
        gas_fee_gwei = default_gwei

    v3_range = st.selectbox("v3 baseline range", ["5pct", "20pct", "full"], index=1,
                            help="Width of the static v3 LP's range around starting price.")
    price_taker = st.checkbox("Price-taker assumption", value=True,
                              help="If on, our LPs do not affect pool dynamics. If off, our liquidity is added to the in-range denominator.")

    run = st.button("Run simulation", type="primary")

# Friendly window label for the title (e.g. "Apr 2025", "May 2024 – May 2025").
if start_date.year == end_date.year and start_date.month == end_date.month:
    window_label = start_date.strftime("%b %Y")
elif start_date.year == end_date.year:
    window_label = f"{start_date.strftime('%b')}–{end_date.strftime('%b %Y')}"
else:
    window_label = f"{start_date.strftime('%b %Y')} – {end_date.strftime('%b %Y')}"

st.title(f"Directional Liquidity Hook — {window_label} backtest")
st.caption(
    "Trade data from USDC/WETH 0.05% on Ethereum Mainnet (deepest pool). "
    "Gas costs configurable per network tier or custom gwei. "
    "4 LPs each deposit $100k at t=0."
)
st.markdown(f"**Data source:** {source_label}")

if run or "result" not in st.session_state:
    cfg = SimConfig(
        bin_width=bin_width,
        twap_window=twap_window,
        keeper_reward_bps=keeper_bps,
        network_tier=network_tier,
        gas_fee_gwei=gas_fee_gwei,
        v3_range=v3_range,
        price_taker=price_taker,
    )
    with st.status("Loading swap data…", expanded=False) as status:
        swaps = cached_load_swaps(start_date.isoformat(), end_date.isoformat())
        n_swaps = len(swaps)
        status.update(label=f"Loaded {n_swaps:,} swaps. Running 4 LPs…")

        progress = st.progress(0.0, text="Simulating…")

        def on_progress(done: int, total: int) -> None:
            # Throttled to ~every 1% by run_sim itself.
            progress.progress(min(done / max(total, 1), 1.0), text=f"Simulating… {done:,}/{total:,} swaps")

        res = run_sim(
            cfg,
            start=start_date.isoformat(),
            end=end_date.isoformat(),
            swaps=swaps,
            progress_callback=on_progress,
        )
        progress.empty()
        status.update(label=f"Done — {n_swaps:,} swaps simulated.", state="complete")
    st.session_state["result"] = res

res = st.session_state["result"]

summary_df = pd.DataFrame(
    [
        dict(
            LP=r.name,
            deposit=r.initial_usd,
            final_value=r.final_value_usd,
            **{"return_%": round(r.return_pct, 2)},
            fees=r.fees_usd,
            principal_drift=r.il_usd,
            keeper_paid=r.keeper_paid_usd,
            rebalances=r.rebalance_count,
        )
        for r in res.summary
    ]
)
ranked = summary_df.sort_values("return_%", ascending=False).reset_index(drop=True)
winner = ranked.iloc[0]["LP"]

st.subheader("Final returns")
col1, col2 = st.columns([2, 3])
with col1:
    st.metric("Winner", winner, f"{ranked.iloc[0]['return_%']:.2f}%")
    st.metric("Runner-up", ranked.iloc[1]["LP"], f"{ranked.iloc[1]['return_%']:.2f}%")

with col2:
    fig = go.Figure()
    colors = ["#2ecc71" if lp == winner else "#7f8c8d" for lp in ranked["LP"]]
    fig.add_trace(
        go.Bar(
            x=ranked["LP"],
            y=ranked["return_%"],
            marker_color=colors,
            text=[f"{v:.1f}%" for v in ranked["return_%"]],
            textposition="outside",
        )
    )
    fig.update_layout(
        yaxis_title="Return (%)",
        title="Final return by LP (winner highlighted)",
        showlegend=False,
        height=380,
    )
    st.plotly_chart(fig, width="stretch", config=PLOTLY_CONFIG)

st.subheader("Summary stats")
st.dataframe(
    summary_df.style.format(
        {
            "deposit": "${:,.0f}",
            "final_value": "${:,.0f}",
            "fees": "${:,.0f}",
            "principal_drift": "${:,.0f}",
            "keeper_paid": "${:,.0f}",
            "return_%": "{:.2f}%",
        }
    ),
    width="stretch",
    hide_index=True,
)

st.subheader("Fees vs principal drift")
decomp = summary_df.copy()
decomp["fees"] = decomp["fees"]
decomp["principal_drift"] = decomp["principal_drift"]
decomp_long = decomp.melt(
    id_vars="LP", value_vars=["fees", "principal_drift"], var_name="component", value_name="usd"
)
fig2 = px.bar(
    decomp_long,
    x="LP",
    y="usd",
    color="component",
    barmode="group",
    color_discrete_map={"fees": "#3498db", "principal_drift": "#e67e22"},
)
fig2.update_layout(yaxis_title="USD", height=380)
st.plotly_chart(fig2, width="stretch", config=PLOTLY_CONFIG)

# --- Time series: LP value lines + ETH price + rebalance markers ---------

ts_df = res.timeseries.copy()
if not ts_df.empty:
    ts_df["dt"] = pd.to_datetime(ts_df["ts"], unit="s", utc=True)
    rb_df = res.rebalances.copy()
    if not rb_df.empty:
        rb_df["dt"] = pd.to_datetime(rb_df["ts"], unit="s", utc=True)

    lp_colors = {
        f"v3 baseline ({v3_range})": "#34495e",
        "Mode Right": "#27ae60",
        "Mode Left": "#c0392b",
        "Mode Both": "#8e44ad",
    }

    st.subheader("LP value over time")
    st.caption(
        "Solid lines: each LP's mark-to-market value + accrued fees, sampled hourly. "
        "Dashed grey: ETH/USD on the right axis. Markers (▼) show rebalance events "
        "per-mode — clusters near sharp price moves are the gate firing on trend "
        "exits; isolated single markers are reversal-driven Mode Both shifts."
    )
    from plotly.subplots import make_subplots

    fig_ts = make_subplots(specs=[[{"secondary_y": True}]])
    for lp_name, group in ts_df.groupby("lp_name"):
        fig_ts.add_trace(
            go.Scatter(
                x=group["dt"],
                y=group["value_usd"],
                mode="lines",
                name=lp_name,
                line=dict(color=lp_colors.get(lp_name, "#7f8c8d"), width=2),
                hovertemplate=f"{lp_name}<br>%{{x|%b %d %H:%M}}<br>$%{{y:,.0f}}<extra></extra>",
            ),
            secondary_y=False,
        )
    # ETH price on secondary axis — pull from any single LP's snapshot
    eth_series = ts_df.groupby("dt")["price"].first().reset_index()
    fig_ts.add_trace(
        go.Scatter(
            x=eth_series["dt"],
            y=eth_series["price"],
            mode="lines",
            name="ETH/USD",
            line=dict(color="#95a5a6", width=1, dash="dash"),
            hovertemplate="ETH/USD<br>%{x|%b %d %H:%M}<br>$%{y:,.0f}<extra></extra>",
        ),
        secondary_y=True,
    )
    # Rebalance markers — per mode, plotted at the LP's own y at that ts
    if not rb_df.empty:
        for lp_name, group in rb_df.groupby("lp_name"):
            joined = group.merge(
                ts_df[["ts", "lp_name", "value_usd"]],
                on=["ts", "lp_name"],
                how="left",
            )
            # If a rebalance happened between snapshots, fall back to the
            # initial deposit value (avoids NaN markers).
            joined["value_usd"] = joined["value_usd"].fillna(100_000.0)
            fig_ts.add_trace(
                go.Scatter(
                    x=pd.to_datetime(joined["ts"], unit="s", utc=True),
                    y=joined["value_usd"],
                    mode="markers",
                    name=f"{lp_name} rebal",
                    marker=dict(
                        symbol="triangle-down",
                        size=9,
                        color=lp_colors.get(lp_name, "#7f8c8d"),
                        line=dict(width=1, color="white"),
                    ),
                    hovertemplate=(
                        f"{lp_name} rebalance<br>%{{x|%b %d %H:%M}}"
                        "<br>ETH $%{customdata:,.0f}<extra></extra>"
                    ),
                    customdata=joined["price"],
                    showlegend=False,
                ),
                secondary_y=False,
            )
    fig_ts.update_layout(
        height=460,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        hovermode="x unified",
    )
    fig_ts.update_yaxes(title_text="LP value (USD)", secondary_y=False)
    fig_ts.update_yaxes(title_text="ETH/USD", secondary_y=True, showgrid=False)
    st.plotly_chart(fig_ts, width="stretch", config=PLOTLY_CONFIG)

    # --- Cumulative fees & principal-drift decomposition over time -------

    st.subheader("Cumulative fees & principal drift over time")
    st.caption(
        "Per-LP breakdown of value evolution. Blue: cumulative fees accruing upward. "
        "Orange: principal value drifting away from initial $100k deposit (negative = "
        "impermanent loss). Their sum is the full LP value line above."
    )
    decomp_cols = st.columns(2)
    lps_ordered = list(ts_df["lp_name"].unique())
    for i, lp_name in enumerate(lps_ordered):
        group = ts_df[ts_df["lp_name"] == lp_name].sort_values("ts")
        principal_drift = group["principal_usd"] - 100_000.0
        fig_d = go.Figure()
        fig_d.add_trace(
            go.Scatter(
                x=group["dt"],
                y=group["fees_usd"],
                mode="lines",
                name="fees",
                line=dict(color="#3498db", width=2),
                fill="tozeroy",
                fillcolor="rgba(52,152,219,0.25)",
            )
        )
        fig_d.add_trace(
            go.Scatter(
                x=group["dt"],
                y=principal_drift,
                mode="lines",
                name="principal drift",
                line=dict(color="#e67e22", width=2),
                fill="tozeroy",
                fillcolor="rgba(230,126,34,0.25)",
            )
        )
        fig_d.add_hline(y=0, line_color="#bdc3c7", line_width=1)
        fig_d.update_layout(
            title=lp_name,
            yaxis_title="USD vs initial deposit",
            height=260,
            margin=dict(l=40, r=20, t=40, b=30),
            legend=dict(orientation="h", yanchor="bottom", y=-0.25, xanchor="center", x=0.5),
        )
        decomp_cols[i % 2].plotly_chart(fig_d, width="stretch", config=PLOTLY_CONFIG)

st.caption(
    "Spec source: spec/DirectionalLiquidityHook-spec.md. Sim mirrors the hook in Python — "
    "no on-chain calls. Fee attribution: analytical share of in-range pool liquidity. "
    "Mark-to-market at window end + accrued fees, no exit slippage modeled."
)
