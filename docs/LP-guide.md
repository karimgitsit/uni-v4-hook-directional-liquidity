# LP Guide

How to provide liquidity through the Directional Liquidity Hook.

## What you're choosing when you pick a mode

Each mode is a single-bin position that sits one bin behind the active
tick. The differences are:

- **Mode Right.** Position to the LEFT of the active tick. Holds the
  quote currency (currency1). When price moves up, the position eventually
  sits a full bin behind, and rebalance shifts it to the new "one bin
  behind." Earns fees only when price moves up *through* the position;
  idle when price moves down.

  Use Mode Right when you have a directional view that the base asset
  will appreciate. You're effectively long the base asset (you keep
  currency1, your "deposit", which appreciates if currency0/currency1
  goes up — wait, this is the part that confuses people).

  More precisely: you deposit currency1. As price goes up, you continue
  to hold currency1 (you're below active, all currency1). You earn fees
  on swaps that cross your bin going up. Your IL exposure is asymmetric
  — you don't lose to downward moves because you don't get swapped
  through on the way down.

- **Mode Left.** Mirror image. Holds the base currency (currency0).
  Earns fees only when price moves DOWN through the position.

- **Mode Both.** Sits one bin behind the LAST direction price moved. If
  price reverses through the position, the position is allowed to be
  swapped through — converting from one currency to the other. After
  TWAP fully exits the OTHER side, the mode reconcentrates on the new
  side (now in the new currency). Captures fees on both directions but
  has full IL exposure.

  Use Mode Both when you have no directional view and want pure fee
  capture. You will rebalance roughly **2× as often** as Right/Left, so
  effective fees-after-keeper-reward are lower.

## When to pick which

| Situation                                       | Mode |
| ----------------------------------------------- | ---- |
| Bullish on base asset, want fees + upside       | Right |
| Bearish on base asset, want fees + downside     | Left |
| No view, just want fee capture                  | Both |
| Want to express a long/short, no fees           | Use a perp, not this |

## Worked example: fees vs IL

Setup: ETH/USDC pool, ETH at $2000, you deposit into Mode Right.

- You deposit 1 ETH worth of USDC = 2000 USDC. Bin width 60 ticks
  (~0.6% price width).
- Position sits at [-60, 0] of active = roughly $1988–$2000 USDC.
- Price moves up to $2010.
- Some swaps cross your bin going up — you earn ~$2 in fees (say).
- TWAP confirms the move. Keeper calls rebalance.
- Your position shifts up to $2000–$2012. You still hold ~2000 USDC,
  but it's now backing a position closer to spot. You missed about $5
  of upside vs holding-2000-USDC because the rebalance happened at the
  TWAP price, not the spot.
- Net: you earned $2 fees - $5 lost upside - keeper-cost pro-rata.

This is the typical Mode Right outcome on continuation moves: small
fee earnings minus a small loss to the rebalance price-shift cost.
On big moves with lots of volume crossing your bin, fees can dominate.

## Withdrawal mechanics

When you withdraw:

- You get back **principal** (your pro-rata share of the mode's current
  liquidity, denominated in whatever currency the position currently
  holds) PLUS **your accumulated fee share** in both currencies.
- The principal currency depends on where the mode is sitting now, not
  what you deposited. If you deposited into Mode Right when the
  position held currency1, then the mode rebalanced multiple times,
  it still holds currency1 — but possibly more or less than you
  deposited (rebalance shifts can shrink or grow per-share liquidity).
- For Mode Both, withdrawal currency could differ from deposit currency
  if a reversal happened between your deposit and withdrawal.
- No oracle settlement. No forced swap. You receive whatever currency
  mix the position holds.

If you withdraw during a "stale" state — TWAP has exited the trigger
but no keeper has called rebalance yet — you receive the mix of the
stale position. If you expect the stale state to differ meaningfully
from a freshly-rebalanced state, call `rebalance()` yourself first
(anyone can; you'll just pay the gas).

## Keeper system

You don't pay rebalance gas directly. Permissionless keepers call
`rebalance()` when triggers fire and earn 5% of the fees collected at
that rebalance as a reward. Effectively your fee yield is reduced by
~5% versus a hypothetical zero-cost rebalance.

The reward is enough that keepers compete to call `rebalance()`
quickly, which keeps the position responsive. The economic floor is
"keeper gas cost ≤ 5% of fees collected" — below that, no one keeps.
On low-volume markets, expect slow rebalances.

## Caveats

- **L2 only in practice.** Rebalance gas costs make this uneconomical
  on Ethereum mainnet for most pools.
- **Mode Both is more expensive to LP than Right/Left** (more frequent
  rebalances).
- **Multi-bin TWAP jumps lose fees on intermediate bins.** If TWAP
  jumps multiple bins between rebalances, your mode skips directly to
  one bin behind current TWAP — you don't earn the intermediate fees.
- **First-deposit warning.** The first deposit into a mode places the
  initial position based on the pool's spot tick. Don't be the first
  depositor on a fresh pool with no trading history — an attacker
  could manipulate the spot to lock the mode's initial range somewhere
  bad.
- **Unaudited.** This is experimental code. Do not put significant
  funds at risk without independent review.
