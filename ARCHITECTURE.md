# Architecture

How the Directional Liquidity Hook fits onto Uniswap v4.

## Per-pool deployment

One hook contract per pool. The `PoolKey` is captured as immutables in
the constructor; the constructor refuses to deploy unless
`poolKey.hooks == address(this)`. Every callback validates the incoming
key against the immutable `poolId`. This keeps the trust surface tight —
the hook only ever services the one pool it was deployed for.

## Three internal mode pools, one v4 pool

The hook tracks three logical "mode pools" — Right, Left, Both — that
share the underlying v4 pool. Each mode independently owns:

- A v4 position (`tickLower`, `tickUpper`, `salt = mode_id`).
- A share count (`totalShares`).
- A per-share fee accumulator (`feePerShareCumulative0/1`).
- A "last shift direction" bit, used by Mode Both.

The three positions are keyed in v4 by their salts (`bytes32(uint256(mode))`),
so even when ranges overlap (e.g. Mode Right and Mode-Both-left can share
a range when Mode Both is positioned to the left of price), v4 attributes
liquidity and fees independently.

## Hook is the LP NFT contract

The hook itself inherits ERC-721. LPs hold NFTs minted by the hook;
each NFT carries:

```
struct PositionInfo {
    uint8   mode;
    uint128 shares;
    uint256 feeSnapshot0;
    uint256 feeSnapshot1;
}
```

The hook is the sole owner of all underlying v4 positions. LPs cannot
modify them directly — `_beforeAddLiquidity` and `_beforeRemoveLiquidity`
revert any external attempt with `DirectLiquidityModificationDisabled`.
Only the hook itself, while inside its own `unlock` callback, may call
`modifyLiquidity` (v4's `Hooks` library short-circuits self-calls so the
beforeAddLiquidity guard doesn't fire on hook-initiated modifies).

## Accumulator-pattern share accounting (worked example)

Fees are tracked per-share, not per-position, à la Synthetix
StakingRewards / MasterChef. Walking through it:

1. Alice deposits 1000 liquidity at mode-init time.
   - `totalShares = 1000` (1:1 init).
   - `feePerShareCumulative0/1 = 0`.
   - Alice's `feeSnapshot0/1 = 0`, `shares = 1000`.

2. The mode collects 100 in currency0 fees (via a swap).
   - On the next interaction (deposit, withdraw, or rebalance), the hook
     pokes the position and accrues:
     `feePerShareCumulative0 += 100 × 2^128 / 1000`
   - Hook physically holds the 100 currency0 as ERC-20 balance.

3. Bob deposits 1000 liquidity.
   - Mode now holds 1000 liquidity (Alice's). Bob's pro-rata shares =
     `1000 × 1000 / 1000 = 1000`. New `totalShares = 2000`.
   - Bob's `feeSnapshot0 = feePerShareCumulative0` (current value), so he
     starts with zero claim on the pre-deposit fees.
   - This is the JIT-attack defense (spec §7.3).

4. Mode collects another 200 currency0 fees.
   - Accumulator advances: `feePerShareCumulative0 += 200 × 2^128 / 2000`.
   - Both Alice (snapshot 0) and Bob (snapshot at step 3) have non-zero
     claims, but Alice's includes the original 100 plus her share of the
     200; Bob's only includes his share of the 200.

5. Alice withdraws her 1000 shares.
   - Pro-rata principal: `1000 × modeLiquidity / totalShares`.
   - Pending fees: `(currentCum - aliceSnapshot) × 1000 / 2^128`.
   - She gets `principal + pending`.
   - Mode's `totalShares` decrements to 1000. The remaining unclaimed
     fees (Bob's portion) stays as ERC-20 on the hook; Bob will collect
     it on his eventual withdraw.

The key invariant: the hook's per-currency ERC-20 balance always covers
the sum of all LPs' pending-fee claims across all modes. Each operation
preserves it: fees in (`take()`) and per-share accrual move in lockstep;
fees out (`transfer` to LP) and snapshot delta move in lockstep.

## TWAP ring buffer

The hook maintains its own internal TWAP — no external oracle. After
every swap, `_afterSwap` writes one observation:

```
struct Observation {
    uint32  timestamp;
    int24   tick;
    int56   tickCumulative;
}
```

into a fixed-size ring buffer (`bufferSize` slots, set at deploy). The
buffer wraps when full. Cost: ~6–10k gas per swap.

`getTwap()` walks the ring buffer to find observations bracketing
`now − twapWindow`, interpolates a cumulative at that point, and returns
the arithmetic-mean tick over the window. If the buffer doesn't yet
span the window (warmup) or no swaps have happened in the window
(low-volume degradation), it falls back to the most-recent tick. Same
behavior as v3's oracle.

## Burn-and-remint rebalance

When `rebalance()` is called, the hook:

1. Computes the current TWAP.
2. Iterates all three modes. For each initialized mode, `nextRebalanceTarget`
   determines whether the trigger fires and what the new range / shift
   direction would be.
3. If at least one mode needs to shift, opens an `unlock` callback.
4. Inside the callback, for each shifting mode:
   - Burns the old v4 position (`modifyLiquidity` with negative delta).
     v4 returns `(callerDelta, feesAccrued)` — principal + fees as a
     positive credit on the manager.
   - `take()`s everything to the hook.
   - Splits `feesAccrued`: keeper gets `keeperRewardBps / 10_000`; the
     rest is folded into the per-share accumulator.
   - Computes the new range's max liquidity from the principal we just
     got back (single-sided — see below).
   - Mints at the new range (`modifyLiquidity` with positive delta) and
     settles from hook ERC-20 balance.
5. After the callback, the hook transfers the keeper their reward in
   one go.

### Single-currency invariant across rebalances

By design every mode's position sits one bin behind the active tick on
exactly one side of price:

- Mode Right and Mode-Both-(dir=false) sit left of active → all currency1.
- Mode Left and Mode-Both-(dir=true) sit right of active → all currency0.

For continuation shifts (price keeps moving in the reactive direction),
the new range is also single-sided in the same currency — burn currency1,
re-deposit currency1.

For Mode-Both **reversal** (price reverses through the position and exits
on the other side), the trigger only fires once TWAP fully exits the
position's bin. By that time, swap-through has converted the position's
holdings into the OTHER currency. So burning gives us currency0 (say),
and the new range — on the new side of price — also takes currency0. The
single-currency invariant holds across the reversal.

This is why the rebalance never has to swap currencies internally: the
burn always produces the currency the new range needs.

## Multi-mode batch rebalance

The `rebalance()` call iterates all three modes inside one `unlock`. v4
nets the currency deltas across the multiple `modifyLiquidity` calls and
the hook settles once per currency at the end. Compared to processing
each mode in its own unlock, this saves per-call fixed costs and
guarantees the rebalance is atomic across modes — no partial state where
some modes shifted and others didn't.

## Last-LP cleanup

When a mode's `totalShares` would go to zero on a withdrawal, the hook
`delete`s the entire `_modes[mode]` slot — accumulator and all. The next
deposit into that mode goes through the lazy-init path again, reading
the current spot tick to place the initial position. This avoids stale
accumulator pollution and division-by-zero edges.

## What the hook intentionally lacks

- **No admin / no upgrade path / no privileged roles.** All parameters
  immutable at deploy. Future changes require a new deployment and LP
  migration. This is a security property, not a missing feature.
- **No external oracle.** TWAP is internal, drawn from swaps on the same
  pool. Trades off oracle dependence for low-volume degradation.
- **No internal swap during rebalance.** Falls out of the
  single-currency invariant above.
- **No partial NFT burn.** Withdraw burns the entire NFT and pays out
  full pro-rata principal + fees. Splitting a position requires
  withdrawing then re-depositing.
