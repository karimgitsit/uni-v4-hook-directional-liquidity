"""Network presets for keeper-gas economics.

Returns a function `gas_per_rebalance_usd(eth_price_usd) -> usd_cost`.
Gas units come from spec §1: ~150-220k per single mode shift, ~350-450k
for batch of three. The mode-LP simulator pays per individual mode
rebalance, so we use the single-mode figure.
"""

from __future__ import annotations

from typing import Callable


GAS_PER_REBALANCE_UNITS = 200_000


PRESETS: dict[str, dict] = {
    "Base":     {"base_fee_gwei": 0.01, "label": "Base"},
    "Optimism": {"base_fee_gwei": 0.05, "label": "Optimism"},
    "Arbitrum": {"base_fee_gwei": 0.10, "label": "Arbitrum"},
    "Mainnet":  {"base_fee_gwei": 5.0,  "label": "Mainnet"},
}


def gas_fn_for_network(name: str) -> Callable[[float], float]:
    cfg = PRESETS[name]
    base_fee_gwei = cfg["base_fee_gwei"]

    def gas_per_rebalance_usd(eth_price_usd: float) -> float:
        eth_cost = GAS_PER_REBALANCE_UNITS * base_fee_gwei * 1e-9
        return eth_cost * eth_price_usd

    return gas_per_rebalance_usd
