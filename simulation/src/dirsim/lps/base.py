"""LP base class. Each subclass overrides on_swap and (optionally)
maybe_rebalance to implement its strategy.

We keep all 4 LPs on a uniform interface so the sim driver can iterate.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..liquidity import Position, sqrt_p_at_tick, position_value_usd
from ..pool import PoolInfo


@dataclass
class SwapEvent:
    ts: int
    tick: int
    sqrt_p: float
    fee_usd: float        # total fee revenue this swap, in USD
    pool_liquidity: float # in-range liquidity at this swap
    price: float          # USD per ETH (token1 per token0, human units)


@dataclass
class LP:
    name: str
    pool: PoolInfo
    deposit_usd: float
    position: Position = field(default=None)  # type: ignore[assignment]
    rebalance_count: int = 0
    keeper_paid_usd: float = 0.0
    initial_value_usd: float = 0.0
    history_value_usd: list[tuple[int, float]] = field(default_factory=list)
    history_fees_usd: list[tuple[int, float]] = field(default_factory=list)

    def on_swap(self, ev: SwapEvent) -> None:
        """Accrue fees if active tick is in range. Default analytical
        share: lp_L / (pool_L + lp_L). With price-taker on, the +lp_L
        in the denominator is dropped by the caller via toggle.
        """
        raise NotImplementedError

    def maybe_rebalance(self, ev: SwapEvent) -> None:
        pass

    def value_usd(self, sqrt_p: float, price: float) -> float:
        if self.position is None:
            return 0.0
        return self.position.value_usd(sqrt_p, price, self.pool) + self.position.fee_usd
