# Keeper Guide

How to run a keeper for the Directional Liquidity Hook.

## What a keeper does

Calls `rebalance()` when at least one mode's TWAP trigger has fired.
Receives `keeperRewardBps / 10_000` (default: 5%) of the fees collected
on the modes that shift in that call.

```solidity
function rebalance() external nonReentrant;
```

No arguments. Anyone can call. Reverts `NothingToRebalance` if no
initialized mode currently needs to shift.

## How to know when a rebalance is profitable

Pre-flight before calling:

1. Read each initialized mode's range and `lastShiftDir`:
   ```solidity
   ModeState s = hook.modeState(mode);
   ```
2. Compute the current TWAP:
   ```solidity
   int24 twap = hook.getTwap();
   ```
3. Evaluate the trigger off-chain:
   ```solidity
   (bool needsShift, , , ) = ModeRange.nextRebalanceTarget(
       mode, twap, s.currentRangeLower, s.currentRangeUpper,
       hook.binTicks(), s.lastShiftDir
   );
   ```
4. Estimate fees collected on a burn:
   - The `modifyLiquidity` returns `feesAccrued` (you can simulate via
     `eth_call`).
   - Your reward = `feesAccrued × keeperRewardBps / 10_000`, in both
     currencies.
5. Estimate gas:
   - One mode shift: ~150–220k gas.
   - All three modes in one call: ~350–450k gas.
6. Profitable iff:
   ```
   reward_value_in_eth > gas_used × gas_price + slop
   ```

## Avoiding wasted calls

`rebalance()` reverts `NothingToRebalance` if no shift is needed. You
pay gas for the failed call. Always pre-check off-chain.

The reward only kicks in on modes that actually shifted. If two modes
trigger at the same time and only one shifts (e.g. the other's same-bin
optimization fires), you only earn the reward on the shifted mode.

## The MEV race

The reward is a permissionless first-come-first-served race. If the
mempool is public, expect competing keepers (and bots) to front-run
your call. Strategies:

- **Private mempool.** Submit through a private RPC (Flashbots-style)
  to avoid public-mempool front-running.
- **Tight monitoring loop.** Watch the pool's swap events and recompute
  TWAP locally; submit the moment a trigger fires.
- **Co-locate.** L2 sequencer-co-located keepers will outpace you on
  L2s with public sequencer endpoints.

## Monitoring TWAP off-chain

The hook's TWAP buffer is in storage. You can:

- Read `_observations[i]` directly via `eth_getStorageAt` (slot layout
  is in the contract).
- Or call the public views: `hook.observationCount()`,
  `hook.observationIndex()`, `hook.getObservation(i)`, `hook.getTwap()`.

Cheaper to maintain a local mirror — subscribe to `Swap` events on the
pool, recompute observations the same way the hook does (one
observation per swap, `tickCumulative` advanced by `prevTick × elapsed`),
and call `getTwap()` only when you suspect a trigger.

## Edge cases

- **Cold buffer.** If no swap has happened in `twapWindow` seconds,
  `getTwap()` returns the most recent tick rather than a real TWAP.
  Triggers can still fire, but the response will be one-step-behind.
- **Mode Both reversal.** Mode Both shifts on both continuation and
  reversal. Track `s.lastShiftDir` to know which way the trigger
  evaluates.
- **Same-bin shift optimization.** If a Mode Both reversal would
  produce a new range identical to the current range (rare geometric
  case), the hook updates `lastShiftDir` in place WITHOUT calling
  `unlock`. You earn no reward on these — it's a free dir-flip from
  your perspective. Pre-check by computing the new range yourself.
- **Zero fees.** If a trigger fires but no fees accrued (extremely
  low-volume mode), the call still proceeds; you just earn nothing.
  Decide in advance whether you want to call profitless rebalances
  (keeps the position responsive for LPs) or skip them.

## Implementation tips

- Cache `binTicks()`, `keeperRewardBps`, the immutable mode ids — they
  never change.
- Don't trust your local TWAP mirror to match on-chain perfectly. Always
  pre-flight via `eth_call` against the actual contract before submitting.
- Use `forge cast` or `viem`/`ethers` for off-chain TWAP eval — both
  support struct decoding for the `ModeState` view.
