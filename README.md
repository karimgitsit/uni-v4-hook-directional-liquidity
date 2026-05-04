# Directional Liquidity Hook

> **⚠️ UNAUDITED — research-grade code. Do not use with production funds.**
> See [`SECURITY.md`](SECURITY.md) and [`docs/self-audit.md`](docs/self-audit.md)
> for the current threat model and self-review. A third-party audit is
> required before any mainnet (or high-TVL L2) deployment.

A Uniswap v4 hook that ports Maverick AMM's directional liquidity modes
(Mode Right, Mode Left, Mode Both) onto v4.

> **Inspired by [Maverick Protocol](https://www.mav.xyz/).** The directional
> mode mechanics (Right / Left / Both, single-bin positions that shift with
> price) are Maverick's design. This project is an independent v4-hook port,
> not affiliated with or endorsed by Maverick.

LPs deposit into one of three directional modes. Each mode holds a
single-bin v4 position that shifts with TWAP, paid for out of accrued
fees by a permissionless keeper.

| Mode  | Initial position relative to active | Reacts to                  | Shifts in direction |
| ----- | ----------------------------------- | -------------------------- | ------------------- |
| Right | One bin left                        | Rightward TWAP exit        | Right (with price)  |
| Left  | One bin right                       | Leftward TWAP exit         | Left (with price)   |
| Both  | One bin behind last move            | Either-direction TWAP exit | With price          |

See the spec at [`spec/DirectionalLiquidityHook-spec.md`](spec/DirectionalLiquidityHook-spec.md) for
the authoritative design. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the v4 mechanics
and [`SECURITY.md`](SECURITY.md) for the security posture.

## Mainnet viability — read this first

This hook is fundamentally an **L2 product**. The math below shows why.

### Keeper unit economics

Rebalances are paid for by `keeperRewardBps` (default 500 = 5%) of the
fees collected during the `rebalance()` burn. A keeper's call is
profitable iff:

```
keeper_reward_value >= gas_cost_value + keeper_margin
```

i.e. iff `0.05 × fees_collected_since_last_rebalance` exceeds the
gas the keeper just spent (in fiat). Approximate per-rebalance gas:

| Operation                              | Gas   |
| -------------------------------------- | ----- |
| Single-mode shift (one bin movement)   | 150–220 k |
| Two modes shifting in one call         | 280–340 k |
| All three modes shifting in one call   | 350–450 k |

(Numbers are estimates from `forge test --gas-report`. Actual
on-chain costs depend on cold/warm storage hits at the specific time
of the rebalance.)

#### Worked break-even fees

Assuming a single-mode shift (220 k gas), 5% keeper reward, and a
0.3% pool fee tier:

| Chain         | Gas price | ETH price | Keeper gas cost | Min. fees per rebalance | Implied min. swap volume |
| ------------- | --------- | --------- | --------------- | ----------------------- | ------------------------ |
| Ethereum L1   | 30 gwei   | $3,000    | $19.80          | $396                    | **$132,000**              |
| Ethereum L1   | 8 gwei    | $3,000    | $5.28           | $106                    | **$35,200**               |
| Base / OP     | 0.05 gwei | $3,000    | $0.033          | $0.66                   | **$220**                  |
| Arbitrum      | 0.01 gwei | $3,000    | $0.0066         | $0.13                   | **$44**                   |

Read this as: the pool must accumulate at least the "min. fees per
rebalance" amount between two consecutive rebalance triggers, or no
rational keeper will call `rebalance()`. On L1 this means the hook is
realistic only for blue-chip pairs at high gas-price quiet — rare. On
L2s the threshold collapses by ~3 orders of magnitude and the hook
becomes economically viable for ordinary pools.

#### What happens if no keeper calls

If fees per cycle are too low to attract a keeper:

- **The hook does not break.** Mode positions stay where they were
  last rebalanced. LPs continue to earn fees on the stale position
  while the price drifts.
- **LPs can self-rebalance.** Any address can call `rebalance()`. An
  LP who would benefit from a fresh range placement can pay the gas
  themselves and forfeit the keeper cut to themselves (no separate
  "self-keeper" mode — they just call as their own keeper).
- **LPs can exit at the stale composition.** `withdraw()` returns
  whatever currency mix the stale position currently holds. No
  forced swap, no oracle pricing — just pro-rata of the current v4
  position.

### Tuning to keep keepers profitable

If you control the deploy parameters of a pool, you can shift the
break-even point:

- **Larger `binWidth`** — rebalance fires less often, so each rebalance
  collects a larger fee batch. Trade-off: each shift converts more
  liquidity, IL per shift goes up.
- **Higher `keeperRewardBps`** — the keeper's slice grows for the same
  fees. Trade-off: LPs pay more for rebalancing. Anything above
  ~2_000 bps is hard to justify; setting `10_000` is allowed by the
  contract but leaves LPs with nothing.
- **Wider `twapWindow`** — fewer false-positive triggers, fewer
  rebalances called by mistake. Less direct effect on fee capture.

### Keepers in practice

Keepers are not a built-in service — they are anyone who wants the
reward. To run one:

1. Watch the on-chain TWAP via `getTwap()` or the off-chain mirror of
   it (recommended — saves a query).
2. Compute whether each mode's trigger condition has fired (the
   `ModeRange.shouldRebalance` function is `pure` and externally
   readable for off-chain use).
3. Estimate gas cost vs. estimated rewards (read pending fees on the
   v4 position via `StateLibrary.getPositionInfo`).
4. Call `rebalance()` if profitable. If multiple modes need shifting,
   one call processes all of them in one `unlock` for net gas savings.
5. Periodically call `claimKeeperReward(to)` to pull accumulated
   rewards out of the hook's escrow into the keeper's wallet.

See [`docs/keeper-guide.md`](docs/keeper-guide.md) for a more
detailed walk-through.

## Mode comparison for LPs

- **Mode Right** — directional bet on the base asset appreciating. Earns
  fees when price moves up, idle when it moves down.
- **Mode Left** — mirror. Directional bet on the quote asset appreciating.
- **Mode Both** — symmetrical, captures fees on both directions, but
  rebalances roughly **2× as often** as Right or Left because it reacts
  to either direction. Gas/keeper costs are paid out of fees, so Mode-
  Both LPs see effectively higher rebalance overhead. Pick Mode Both
  only if you have no directional view and want pure fee capture.

See [`docs/LP-guide.md`](docs/LP-guide.md) for full LP-side guidance.

## Who benefits from this hook

Two distinct audiences, with different reasons to use it.

### Third-party LPs

You're depositing capital and choosing a directional view at the same time.

- **Pick a stance, not a range.** Mode Right, Left, or Both. The hook handles the v4 range placement and shifts it for you as TWAP moves. No manual re-ranging, no off-chain bot.
- **Capital efficiency of a single-bin position.** Your liquidity is always concentrated one bin behind active price (or one bin behind the last move, for Mode Both), so fee capture per dollar deposited is dramatically higher than a wide v3 range — provided a keeper keeps you current.
- **Directional alignment with IL.** Mode Right keeps inventory weighted in the base asset as price rises (instead of being converted through it the way a symmetric LP would). Mode Left mirrors that for downward moves. You take less IL when you're directionally right.

### Token issuers (LSTs, stablecoins, protocol tokens)

You're seeding protocol-owned liquidity for a token whose price has a known shape.

- **Deploy POL that matches your token's expected price path.** An LST that drifts upward against ETH? Seed Mode Right — POL trails the appreciation automatically, no quarterly re-deploy. A stablecoin clustered around peg? Seed Mode Both with a narrow bin width and stay concentrated on the peg without manual ops. Worried about a directional depeg? Mode Left puts you on the bid as price falls.
- **No active liquidity-management headcount.** No scripts, no keeper bot of your own, no MM contract. The hook plus public keepers handle range placement.

**What both audiences need to accept:** this hook is **L2-only** for any token short of blue-chip volume — see the keeper unit-economics table above. On mainnet outside top pairs, keepers won't call `rebalance()`, positions drift out of range, and the hook's whole value proposition breaks. Deploy on Base, Arbitrum, Optimism, or similar.

## Quick start

```bash
# 1. Install deps. `OpenZeppelin/uniswap-hooks` ships v4-core,
#    v4-periphery, openzeppelin-contracts, solmate, and permit2 as
#    transitive dependencies — no need to install them separately.
forge install foundry-rs/forge-std
forge install OpenZeppelin/uniswap-hooks

# 2. Build and test
forge build
forge test

# 3. Deploy. The hook address must encode the right permission flags;
#    the script mines a CREATE2 salt that lands at a valid address.
forge script script/DeployDirectionalLiquidityHook.s.sol \
  --rpc-url $RPC --broadcast \
  --sig 'run(address,address,address,uint24,int24,uint24,uint32,uint16,uint16,string,string)' \
  $POOL_MANAGER $TOKEN0 $TOKEN1 \
  $FEE $TICK_SPACING \
  $BIN_WIDTH $TWAP_WINDOW $KEEPER_BPS $BUFFER \
  "Directional Liquidity Position" "DLP"
```

## Deployment parameters

The hook is **per-pool, immutable**. One contract per `(token0, token1, fee,
tickSpacing)` tuple. All non-PoolManager parameters are immutables set in
the constructor and cannot be changed after deploy.

| Parameter         | Type     | Notes |
| ----------------- | -------- | ----- |
| `poolManager`     | address  | Canonical v4 PoolManager for the chain |
| `poolKey`         | struct   | Standard v4 `PoolKey`; `hooks` must equal the deployed hook address |
| `binWidth`        | uint24   | Bin width as a multiple of `tickSpacing`. Must be > 0; the product `binWidth × tickSpacing` must be ≤ 443_636 (= `MAX_TICK / 2`) so rebalance arithmetic stays within `int24` for any in-range tick |
| `twapWindow`      | uint32   | TWAP window in seconds. 600 (10 min) is a reasonable L2 default |
| `keeperRewardBps` | uint16   | Keeper's cut of fees, in basis points (out of 10_000). Spec default: 500 (5%) |
| `bufferSize`      | uint16   | TWAP ring-buffer size. Minimum is 8 (smaller buffers degrade TWAP into "always last tick" — see `MIN_BUFFER_SIZE` in the hook). 64 is a reasonable L2 default |
| `name`/`symbol`   | string   | LP NFT metadata |

How to choose them:
- **`binWidth`**: trade off rebalance frequency against IL per shift. Wider
  bins shift less often (lower keeper costs) but each shift converts more
  liquidity, so impermanent loss per shift is larger. For volatile pairs,
  prefer narrower bins.
- **`twapWindow`**: short enough to react to real moves, long enough to
  reject manipulation. L2 block time × ~100 is a starting point.
- **`bufferSize`**: must be large enough to retain at least one observation
  older than `twapWindow` under expected swap frequency. Errs harmless on
  the high side (just costs storage). Floored at 8 by the constructor — a
  smaller buffer makes the TWAP collapse to "always last tick" and exposes
  rebalance triggers to single-block manipulation.

  Recommended starting points (assume ~1 swap-per-block in active hours;
  scale up for thinner pools so the buffer still spans `twapWindow` even
  during quiet periods):

  | Chain target | Block time | `twapWindow` | Recommended `bufferSize` |
  | ------------ | ---------- | ------------ | ------------------------ |
  | Ethereum L1  | ~12 s      | 600 s        | 64                       |
  | Base / OP / Polygon | ~2 s | 600 s     | 64                       |
  | Arbitrum     | ~0.25 s    | 600 s        | 256 (or higher)          |

  The deploy script logs a per-chain coverage table so you can sanity-check
  the chosen `bufferSize × block_time ≥ twapWindow` before broadcasting.

- **`keeperRewardBps`**: enough to cover keeper gas + slop. Higher = more
  responsive rebalances, but more LP fees go to keepers. **Do not set
  `keeperRewardBps == 10_000`** — a 100% keeper share zeros LP fee
  accrual entirely. The constructor permits values up to 10_000 to keep
  the bounds simple, but anything above ~2_000 (20%) is hard to justify
  economically. Spec default of 500 (5%) is a reasonable starting point.

## Repository layout

```
src/
  DirectionalLiquidityHook.sol   ← the hook
  libraries/
    ShareMath.sol                ← share + fee accumulator math
    ModeRange.sol                ← range geometry + shift triggers
script/
  DeployDirectionalLiquidityHook.s.sol  ← CREATE2 salt mining + deploy
test/                            ← Foundry tests
spec/                            ← authoritative spec
reference/                       ← v4 interface + example-hook references
```

## Audit status

**Unaudited.** A self-audit lives at
[`docs/self-audit.md`](docs/self-audit.md) covering the
Uniswap-Foundation security framework checklist plus four supporting
audit guides. All findings flagged in that document have been either
closed or marked as documentation-only follow-ups; this is **not** a
substitute for an independent third-party audit. Do not use with
production funds until at least one external audit lands. For
custodial deployments or `*ReturnDelta`-style economic exposure, two
independent audits are the responsible bar.
