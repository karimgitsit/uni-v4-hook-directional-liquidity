"""Network gas-cost helpers for keeper economics.

Gas units come from spec §1: ~150-220k per single mode shift, ~350-450k
for batch of three. The mode-LP simulator pays per individual mode
rebalance, so we use the single-mode figure.

The UI now picks a network *tier* (Layer 1 / Layer 2 / Custom) rather
than a specific chain name; default gwei values for each tier live in
`NETWORK_DEFAULTS`. `Custom` lets the user dial in any gwei value.
"""

from __future__ import annotations

from typing import Callable


GAS_PER_REBALANCE_UNITS = 200_000


NETWORK_DEFAULTS: dict[str, float] = {
    "Layer 1": 5.0,    # ~Mainnet typical base fee
    "Layer 2": 0.05,   # ~Optimism / Base typical base fee
}


def gas_fn(gas_fee_gwei: float) -> Callable[[float], float]:
    """Build a `eth_price_usd -> usd_cost_per_rebalance` function."""

    def gas_per_rebalance_usd(eth_price_usd: float) -> float:
        eth_cost = GAS_PER_REBALANCE_UNITS * gas_fee_gwei * 1e-9
        return eth_cost * eth_price_usd

    return gas_per_rebalance_usd
