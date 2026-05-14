"""Streamlit calculator for the Directional Liquidity Hook backtest.

Run from the simulation/ directory:

    PYTHONPATH=src streamlit run app.py

Set SUBGRAPH_URL to use real Uniswap v3 Base data; otherwise the app
falls back to a synthetic GBM dataset (clearly labeled).
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd

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

from dirsim.data import load_swaps
from dirsim.pool import BASE_USDC_ETH_005
from dirsim.presets import PRESETS
from dirsim.sim import SimConfig, run_sim


st.set_page_config(page_title="Directional Liquidity Hook — Backtest", layout="wide")
st.title("Directional Liquidity Hook — April 2025 backtest")
st.caption(
    "Trade data from USDC/WETH 0.05% on Ethereum Mainnet (deepest pool). "
    "Gas costs configurable per network — try Base/Optimism vs Mainnet to "
    "see how the hook's economics change. 4 LPs each deposit $100k at t=0."
)

_has_subgraph = bool(os.environ.get("SUBGRAPH_URL") or os.environ.get("GRAPH_API_KEY"))
source_label = (
    "Real subgraph data"
    if _has_subgraph
    else "⚠ Synthetic data — set GRAPH_API_KEY in simulation/.env for real Mainnet data"
)
st.markdown(f"**Data source:** {source_label}")

with st.sidebar:
    st.header("Hook parameters")
    bin_width = st.slider("binWidth (× tickSpacing)", min_value=1, max_value=50, value=10, step=1,
                          help="Width of each mode's single-bin position. tickSpacing=10 for the 0.05% pool.")
    twap_window = st.slider("twapWindow (seconds)", min_value=60, max_value=3600, value=600, step=60,
                            help="Window over which the rebalance trigger averages tick.")
    keeper_bps = st.slider("Keeper reward (bps of fees)", min_value=0, max_value=2000, value=500, step=50,
                           help="% of fees per rebalance paid to whoever calls it. Spec default 500 (5%).")

    st.header("Environment")
    network = st.selectbox("Network preset", list(PRESETS.keys()), index=0,
                           help="Sets gas-per-rebalance cost (200k gas × base fee).")
    v3_range = st.selectbox("v3 baseline range", ["5pct", "20pct", "full"], index=1,
                            help="Width of the static v3 LP's range around starting price.")
    price_taker = st.checkbox("Price-taker assumption", value=True,
                              help="If on, our LPs do not affect pool dynamics. If off, our liquidity is added to the in-range denominator.")

    run = st.button("Run simulation", type="primary")

if run or "result" not in st.session_state:
    cfg = SimConfig(
        bin_width=bin_width,
        twap_window=twap_window,
        keeper_reward_bps=keeper_bps,
        network=network,
        v3_range=v3_range,
        price_taker=price_taker,
    )
    with st.spinner("Running…"):
        res = run_sim(cfg)
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
    st.plotly_chart(fig, width="stretch")

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
st.plotly_chart(fig2, width="stretch")

st.caption(
    "Spec source: spec/DirectionalLiquidityHook-spec.md. Sim mirrors the hook in Python — "
    "no on-chain calls. Fee attribution: analytical share of in-range pool liquidity. "
    "Mark-to-market on April 30 + accrued fees, no exit slippage modeled."
)
