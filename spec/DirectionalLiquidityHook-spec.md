# Directional Liquidity Hook — Specification

A Uniswap v4 hook that ports Maverick AMM's directional liquidity modes
(Mode Right, Mode Left, Mode Both) onto v4.

**Status:** Design spec, pre-implementation. No code yet.
**Target:** Solidity ^0.8.24, Foundry, v4-periphery `BaseHook`.

---

## 1. Overview and design goals

### What this hook does

LPs deposit into one of three directional modes:

- **Mode Right** — single-bin position immediately left of active. Reacts only
  to rightward (upward) TWAP movement. Directional bet on the base asset
  appreciating.
- **Mode Left** — mirror. Single-bin position immediately right of active.
  Reacts only to leftward TWAP movement.
- **Mode Both** — single-bin position one bin behind price in whichever
  direction it last moved. Reacts to both directions. Higher fee capture,
  higher IL exposure.

All three modes shift their underlying v4 position based on TWAP, not spot
price. Shifts are triggered by a permissionless `rebalance()` keeper call,
paid out of accrued fees.

### Design goals

1. **Faithful Maverick port** within v4's constraints.
2. **Zero per-swap overhead beyond a tiny TWAP observation write.**
3. **O(1) rebalance cost in number of LPs.** Accumulator-pattern share
   accounting, no LP iteration.
4. **No external trust assumptions.** No external oracle. TWAP is internal.
5. **Per-pool isolation.** One hook contract per pool, validated `PoolKey`
   on every callback.

### Explicit non-goals (v1)

- **Mode Static.** Out of scope. Static LPing is a solved problem and the
  hook adds no value over standard v4 LPing for static positions.
- **Active-bin opt-in deposits.** Maverick lets LPs optionally place liquidity
  in the active bin. v1 does not — all deposits go into the mode's standard
  one-bin-behind-active position.
- **Multi-bin-width modes within a single hook deployment.** `binWidth` is
  immutable per hook deployment. Different widths require separate
  deployments.
- **Forced rebalances or rebalance cooldowns.** Keepers self-regulate via
  reward economics.

### Mainnet viability

This hook is fundamentally an L2 product. Rebalance gas costs (~150-220k per
mode shift, ~350-450k for all three in one call) make it economically
unviable on mainnet except for blue-chip pairs with high enough fee accrual
to justify keeper rewards. **The README must document this prominently.**

---

## 2. Architecture

### Contract structure

A single contract, `DirectionalLiquidityHook`, that inherits from:

- `BaseHook` (v4-periphery) — for hook lifecycle integration.
- `ERC721` — the hook itself is the LP NFT contract.
- `ReentrancyGuard` — for external entry points (`deposit`, `withdraw`,
  `rebalance`).

### Per-pool hook deployment

One hook contract per pool. The hook stores its `PoolKey` immutably at
construction and validates `msg.sender == address(poolManager)` and the
incoming `PoolKey` on every callback. Anyone can deploy their own instance
for any pool.

### Internal mode pools

The hook tracks three internal "mode pools" (`Right`, `Left`, `Both`). All
three share the same underlying v4 pool. Each mode independently:

- Holds one v4 position (range tracked in mode state).
- Maintains its own share-accounting accumulator.
- Tracks its own most-recent-rebalance state for shift-trigger evaluation.

### LP positions

LPs hold ERC-721 NFTs minted by the hook. Each NFT carries:

- `mode` — Right, Left, or Both.
- `shares` — share count in the mode's accumulator.
- `feeSnapshot0`, `feeSnapshot1` — accumulator values at mint/update time.

The same address can hold multiple NFTs in different modes.

### Position ownership

The hook is the sole owner of all v4 positions for the pool. LPs interact
exclusively through the hook (`deposit`/`withdraw`); they cannot directly
modify the underlying v4 positions.

---

## 3. Mode definitions

### Geometry

All three modes hold **single-bin positions of identical width**. The only
difference between modes is the *trigger* for shifting and the *direction*
of the shift.

- One bin = `binWidth × tickSpacing` ticks wide. `binWidth` is immutable
  per deployment.
- All modes' positions sit "one bin behind" the active tick in the relevant
  direction.

| Mode  | Initial position relative to active | Reacts to                   | Shifts in direction |
| ----- | ----------------------------------- | --------------------------- | ------------------- |
| Right | One bin left                        | Rightward TWAP exit         | Right (with price)  |
| Left  | One bin right                       | Leftward TWAP exit          | Left (with price)   |
| Both  | One bin behind last move            | Either-direction TWAP exit  | With price          |

### Universal shift trigger rule

A mode rebalances when **TWAP exits the bin "ahead of" the position in the
mode's reactive direction.** Concretely:

- **Mode Right.** Position at [active - binWidth, active]. Trigger: TWAP
  exits the active bin going right (i.e., TWAP > active bin upper).
  Reconcentrate one bin to the right.
- **Mode Left.** Position at [active, active + binWidth]. Trigger: TWAP
  exits the active bin going left (TWAP < active bin lower). Reconcentrate
  one bin to the left.
- **Mode Both.** Position is one bin behind the last move's direction.
  Trigger: TWAP exits the bin "ahead of" the position. If the position is
  to the left of price, trigger fires on rightward exit of the bin to its
  right (continuation). If price reverses through the position, the
  position is allowed to be swapped through (no rebalance), and only after
  TWAP exits the *other side* does it reconcentrate to the new side.

This "swap through completely before reversing" behavior matches Maverick's
described mechanic and emerges naturally from the universal rule above:
when the position is itself the active bin, no rebalance fires; only after
TWAP exits the position's bin does it shift.

### Multi-bin TWAP jumps

If TWAP has moved multiple bins since the last rebalance for a mode, the
mode shifts directly to the bin one behind current TWAP. No intermediate
hops. LPs do not earn fees retroactively for bins they were not in;
documented as a slow-keeper cost.

### Mode-Both shift direction tracking

Mode Both needs to know which direction it last shifted in to determine
position placement. Stored as a single bit in `ModeState`: `lastShiftDir`
(0 = right-of-position, 1 = left-of-position). On each Mode-Both rebalance,
update based on the direction TWAP exited.

---

## 4. TWAP source

### Approach: minimal observation buffer (no external oracle)

The hook maintains its own TWAP observation buffer, populated via `afterSwap`.
No external oracle is used.

### Observation structure

```
struct Observation {
    uint32  timestamp;        // observation time
    int24   tick;             // tick at observation time
    int56   tickCumulative;   // sum of (tick × elapsed) since deployment
}
```

Stored in a fixed-size ring buffer of size `BUFFER_SIZE`, sized at
deployment to ensure at least one observation older than `twapWindow`
seconds is always retained even in adverse cases. Default sizing: enough
to cover `twapWindow` at expected swap frequency for the target chain
(L2-typical: 64 slots is generally sufficient).

### Per-swap overhead

`afterSwap` writes one observation. Realistic cost: **~6-10k gas per swap**
with packed storage. This is the only per-swap overhead the hook adds.
Documented as an explicit tradeoff vs. external-oracle alternatives.

### TWAP query

`getTwap()` walks back through the ring buffer to find observations
bracketing `now - twapWindow` and interpolates. Used by `rebalance()` to
evaluate shift triggers. Not called per swap.

### Low-volume pool degradation

If no swap has occurred for longer than `twapWindow`, TWAP returns the tick
of the most recent observation. Standard property of all swap-driven TWAP
designs (same as v3 oracle). Documented as a known limitation. Mode
behavior degrades gracefully in this case (no false triggers, just
slow response when activity resumes).

### Buffer initialization

On hook deployment, the buffer is empty. The first `afterSwap` seeds the
buffer. Until at least two observations span `twapWindow`, `getTwap()`
returns the most recent observation's tick (or reverts if no observations
exist). Deposits and rebalances must handle this gracefully:

- **First deposit** uses pool's current tick (not TWAP) for initial range
  placement, since TWAP may not yet be available. See §5.1.
- **Rebalance** reverts if no usable TWAP exists yet.

---

## 5. Lifecycle

### 5.1 First deposit (lazy mode initialization)

Per-mode state has an `initialized` flag, false on deployment.

When the first deposit into a mode arrives:

1. Read pool's current tick (via `extsload` / `StateLibrary`).
2. Compute mode's initial range based on current tick and `binWidth`.
3. Mint position with deposited liquidity into PoolManager.
4. Set `totalShares = liquidity` (1:1 initialization).
5. Issue NFT to depositor with `feeSnapshot = 0` (accumulator is fresh).
6. Mark mode as `initialized = true`.
7. Set `lastShiftDir` for Mode Both based on initial position placement.

### 5.2 Subsequent deposits

1. Compute pro-rata shares: `sharesIssued = depositLiquidity × totalShares /
   modeCurrentLiquidity`.
2. Update mode's fee accumulator (`feePerShareCumulative0/1`) based on
   fees accrued since last accumulator update.
3. Mint additional liquidity into the mode's existing position via
   PoolManager.
4. Issue NFT with current accumulator values as `feeSnapshot`.
5. `totalShares += sharesIssued`.

### 5.3 Withdrawals

1. Read NFT's `mode`, `shares`, `feeSnapshot`.
2. Compute pro-rata liquidity to remove: `liquidityOut = shares ×
   modeCurrentLiquidity / totalShares`.
3. Update fee accumulator before withdrawal.
4. Compute fees owed: `(currentAccumulator - feeSnapshot) × shares`.
5. Burn liquidity from PoolManager position, receiving currency0 and
   currency1 amounts proportional to current position composition.
6. Transfer principal + fees to LP.
7. Burn NFT.
8. `totalShares -= shares`.
9. **If `totalShares == 0` after withdrawal:** set `initialized = false`,
   zero out range and accumulator state. Next deposit re-initializes.

LPs receive whatever currency mix the position currently holds — no
forced swap, no oracle-priced settlement.

### 5.4 Rebalance

`rebalance()` is permissionless and processes all three modes in a single
call.

```
function rebalance() external nonReentrant {
    // 1. Get current TWAP
    int24 twap = getTwap();

    // 2. For each mode, evaluate shift trigger
    bool[3] memory shouldShift;
    int24[3] memory newRangeLower;
    int24[3] memory newRangeUpper;

    for each mode:
        if mode.initialized && shouldRebalance(mode, twap):
            compute new range
            shouldShift[i] = true

    // 3. If nothing to shift, revert
    require(any(shouldShift), "Nothing to rebalance");

    // 4. Single unlock callback handles all shifts atomically
    poolManager.unlock(abi.encode(shouldShift, newRangeLower, newRangeUpper));

    // 5. Pay keeper reward (5% of fees collected this rebalance)
    payKeeperReward(msg.sender);
}
```

Inside the unlock callback:

- For each shifting mode: burn old position (collects fees), mint new
  position at new range with the same total liquidity.
- Net all currency deltas across modes; settle the net amount with
  PoolManager once.
- Update each shifting mode's `currentRangeLower/Upper` and accumulator.

### 5.5 No-op optimizations

- **Empty mode (`!initialized`):** skip evaluation; no contribution to
  "should rebalance" check.
- **Same-bin trigger (TWAP crossed and came back):** if computed new range
  equals current range for a mode, do not include that mode in the unlock
  callback. Saves one burn-mint pair.
- **All modes empty or no shifts needed:** `rebalance()` reverts. Keeper
  pays gas for the failed call but nothing breaks.

### 5.6 Withdrawals during stale state

If TWAP has crossed a mode's trigger but no keeper has called `rebalance()`
yet, withdrawals proceed against the stale position. The LP receives the
currency mix of the stale position, which may differ from what they'd get
post-rebalance. **This is accepted behavior** — LPs are free to call
`rebalance()` themselves before withdrawing if they expect a meaningful
difference.

---

## 6. Storage layout

### Per-mode state

```
struct ModeState {
    int24   currentRangeLower;
    int24   currentRangeUpper;
    uint128 totalShares;
    uint256 feePerShareCumulative0;
    uint256 feePerShareCumulative1;
    bool    initialized;
    bool    lastShiftDir;          // Mode Both only; ignored for Right/Left
}

mapping(uint8 mode => ModeState) modes;  // 0=Right, 1=Left, 2=Both
```

Pack `currentRangeLower`/`Upper`/`totalShares`/`initialized`/`lastShiftDir`
into one slot. Accumulators get their own slots (large values).

### Per-NFT state

```
struct PositionInfo {
    uint8   mode;
    uint128 shares;
    uint256 feeSnapshot0;
    uint256 feeSnapshot1;
}

mapping(uint256 tokenId => PositionInfo) positions;
```

### TWAP buffer

```
Observation[BUFFER_SIZE] observations;
uint16 observationIndex;     // ring buffer head
uint16 observationCount;     // grows up to BUFFER_SIZE then stays
```

### Immutables

```
PoolKey  poolKey;             // immutable, set in constructor
PoolId   poolId;              // derived from poolKey, also immutable
uint24   binWidth;            // multiples of tickSpacing
uint32   twapWindow;          // seconds
uint16   keeperRewardBps;     // 500 = 5%
uint16   bufferSize;          // ring buffer size for observations
```

### Hook permissions

```
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize:        false,
        afterInitialize:         false,
        beforeAddLiquidity:      true,   // block direct LP adds
        afterAddLiquidity:       false,
        beforeRemoveLiquidity:   true,   // block direct LP removes
        afterRemoveLiquidity:    false,
        beforeSwap:              false,
        afterSwap:               true,   // TWAP observation
        beforeDonate:            false,
        afterDonate:             false,
        beforeSwapReturnDelta:   false,
        afterSwapReturnDelta:    false,
        afterAddLiquidityReturnDelta:    false,
        afterRemoveLiquidityReturnDelta: false
    });
}
```

`beforeAddLiquidity` and `beforeRemoveLiquidity` revert unless
`msg.sender == address(this)` (i.e., the hook is acting on behalf of LPs).
This prevents external direct modification of the hook-owned positions.

---

## 7. Security considerations

These are specific to this hook. Generic security defaults from the system
prompt apply additionally.

### 7.1 PoolKey / PoolManager validation

Every callback (`afterSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`,
`unlockCallback`) must:

- Verify `msg.sender == address(poolManager)`.
- Verify the incoming `PoolKey` matches the immutable `poolKey` (if a key
  is passed).

### 7.2 Reentrancy

External entry points (`deposit`, `withdraw`, `rebalance`) use
`ReentrancyGuard`. The unlock callback is reentrant by design within a
single transaction (PoolManager calls back into the hook), so the guard
must be designed to allow that specific re-entry while blocking external
re-entry.

### 7.3 Keeper reward MEV

The keeper reward is paid to whoever calls `rebalance()` first after the
trigger condition is met. This is a permissionless MEV race:

- **Front-running**: an actor watching TWAP can call `rebalance()` the
  moment the trigger fires, capturing the reward over slower keepers.
- **No JIT-deposit attack**: the accumulator pattern correctly prevents
  newly-deposited LPs from claiming pre-deposit fees, because `feeSnapshot`
  is taken at deposit time.

The keeper-reward MEV race is acknowledged and accepted. Mitigations
(decaying reward over time, etc.) are out of scope for v1 and noted as
future work in docs.

### 7.4 First-deposit manipulation

The first deposit into a mode reads the pool's current tick (not TWAP) to
place the initial position. An attacker could:

1. Initialize a fresh pool at a manipulated tick.
2. Be the first depositor, locking the mode's initial position at that
   tick.
3. Move the pool back; the mode's position is now in a "wrong" range.

Mitigations:

- Document that hook deployments should target pools with non-trivial
  trading history before significant deposits.
- Optional: require buffer to have at least N observations before first
  deposit can proceed, falling back to TWAP if available. **Decide during
  implementation.**

### 7.5 Last-LP withdrawal cleanup

When `totalShares` would go to zero, the cleanup path resets
`initialized = false` and zeroes accumulators. Next deposit re-initializes
from scratch. Tested explicitly to ensure no division-by-zero or stale
accumulator pollution.

### 7.6 Shared-pool fee attribution

Three modes hold separate v4 positions with potentially overlapping ranges
(Mode Right's range and Mode Both's range can overlap when Mode Both is
positioned to the left of price). v4 attributes fees per-position
correctly. No special handling required — but tested explicitly to confirm
fee distribution works as expected when ranges overlap.

### 7.7 Multi-bin TWAP jump correctness

When TWAP has jumped multiple bins, the mode shifts directly to the
one-bin-behind-current-TWAP position. Documented and tested — LPs do not
earn fees for intermediate bins.

### 7.8 No upgradeability, no privileged roles

The hook has no admin, no upgrade path, no role-gated functions. All
parameters are immutable. This is intentional and is a security property
worth highlighting in the README. Any future changes require a new
deployment and LP migration.

### 7.9 ERC-721 + reentrancy interaction

NFT mints during deposit happen *after* PoolManager state is settled.
ERC-721 `_safeMint` calls `onERC721Received` on contract recipients, which
is a reentry surface. Either:

- Use `_mint` (no callback) for the deposit flow.
- Or use `_safeMint` with the deposit flow already complete and
  ReentrancyGuard active.

**Decide during implementation.** Default to `_mint` unless a use case for
`_safeMint` is identified.

### 7.10 Mode Both economics for LPs

Mode Both shifts roughly 2× as often as Mode Right or Mode Left because it
reacts to either direction. Since rebalance gas costs are paid out of fees
via the keeper reward, Mode Both LPs effectively pay more for rebalancing
than Mode Right/Left LPs. This is correct economics, not a bug, but must
be documented in LP-facing docs.

---

## 8. Testing requirements

Per the system prompt, the hook gets a matching `DirectionalLiquidityHook.t.sol`
with at minimum:

- **Initialization test.** Deploy hook, verify immutables, verify initial
  state of all three modes is uninitialized.
- **Permission flag test.** Verify `getHookPermissions()` returns exactly
  `beforeAddLiquidity | beforeRemoveLiquidity | afterSwap` and nothing
  else.
- **Happy-path callback tests.** First deposit (each mode), subsequent
  deposit, withdrawal, full withdrawal (last LP), rebalance.
- **Adversarial tests.** Each at minimum:
  - `afterSwap` called by non-PoolManager caller (must revert).
  - Direct `modifyLiquidity` attempt against the pool (blocked by
    `beforeAddLiquidity`).
  - `rebalance()` called when no modes need shifting (must revert).
  - `rebalance()` called when no modes are initialized (must revert).
  - Withdrawal during stale rebalance state (proceeds, returns stale mix).
  - Reentrancy attempt via callback (must revert).

Additional tests strongly recommended:

- Mode Both swap-through-and-reverse behavior.
- Multi-bin TWAP jump rebalance.
- Same-bin trigger no-op optimization.
- Three-mode batch rebalance in single `unlock`.
- Fee accumulator precision under low-volume mode.
- Last-LP withdrawal then re-deposit (mode re-initialization).
- TWAP buffer wraparound.
- Buffer-not-yet-warm behavior on early deposits.

Tests use `deployFreshManagerAndRouters` from v4-template fixtures. Run
against local anvil with `--code-size-limit 30000`.

---

## 9. Deployment

A `script/DeployDirectionalLiquidityHook.s.sol` script:

1. Computes required hook permission flags.
2. Uses `HookMiner` (CREATE2 salt mining) to find a salt that produces an
   address with the correct permission bits encoded.
3. Deploys via CREATE2 with the mined salt.
4. Logs deployed address and salt for verification.

Constructor parameters:

- `IPoolManager poolManager`
- `PoolKey poolKey`
- `uint24 binWidth` (multiples of `poolKey.tickSpacing`)
- `uint32 twapWindow` (seconds)
- `uint16 keeperRewardBps` (e.g., 500 = 5%)
- `uint16 bufferSize` (ring buffer size; e.g., 64)
- ERC-721 name and symbol

All non-PoolManager parameters are stored as immutables.

---

## 10. Documentation requirements

The hook ships with the following documentation, all written before
mainnet/L2 deployment:

### 10.1 README.md

- What the hook is and what problem it solves.
- The three modes, plain-language explanation aimed at LPs.
- **Mainnet viability caveat** (gas-cost reality, L2-first product).
- **Mode Both is more expensive to LP** than Mode Right/Left (more
  frequent rebalances).
- Deployment parameters and how to choose them (`binWidth`, `twapWindow`,
  `keeperRewardBps`, `bufferSize`).
- Quick-start: how to deploy, how to deposit, how to withdraw.

### 10.2 ARCHITECTURE.md

- Per-pool hook deployment model.
- Three internal mode pools sharing one v4 pool.
- Hook-as-ERC-721 design.
- Accumulator-pattern share accounting (with worked example).
- TWAP buffer mechanics.
- Burn-and-remint rebalance flow with single-unlock netting.

### 10.3 SECURITY.md

- All items in §7 of this spec.
- Known limitations:
  - Keeper-reward MEV race.
  - First-deposit tick-manipulation surface (mitigations).
  - Low-volume TWAP degradation.
  - Multi-bin jumps mean missed intermediate fee capture.
- No upgradeability, no admin — **intentional, not a missing feature.**
- Audit status (initially: unaudited, do not use with production funds).

### 10.4 LP guide (user-facing)

- Plain-English mode comparison.
- "When would I use which mode?" — directional bet vs. pure fee capture.
- Worked example of fees vs. IL for each mode.
- Withdrawal mechanics: pro-rata in current currency mix.
- Keeper system: what it is, why LPs don't pay rebalance gas directly,
  why fees are slightly lower than they'd otherwise be.

### 10.5 Keeper guide

- How to monitor the pool's TWAP.
- How to compute whether `rebalance()` would be profitable given current
  gas prices and accrued fees.
- The MEV race for the keeper reward.

### 10.6 Inline NatSpec

Every public/external function gets full NatSpec including:

- `@notice` plain-English description.
- `@dev` implementation notes for reviewers.
- `@param` and `@return` for all inputs/outputs.
- For functions returning deltas (`unlockCallback` flow): explicit comments
  on sign convention and direction.

---

## 11. Open implementation questions

To resolve during coding, not now:

1. **`_mint` vs `_safeMint` for LP NFTs.** Default `_mint` unless a use
   case requires `_safeMint`.
2. **Buffer-warmup requirement on first deposit.** Whether to require N
   observations before any deposit, or just fall back to spot tick. Default
   to spot tick fallback unless first-deposit manipulation analysis
   suggests otherwise.
3. **Exact `bufferSize` default.** Compute from target chain block time and
   `twapWindow` — 64 is a reasonable starting point for L2s.
4. **Keeper reward edge case: zero fees collected.** If `rebalance()` is
   called and the position needs shifting but no fees have accrued
   (extremely low-volume mode), the keeper gets nothing. Should the call
   still proceed (consistency) or revert (don't waste keeper gas on
   no-reward calls)? Default to proceed — keeper made the choice to call.

---

## 12. Out-of-scope, future work

- Decaying keeper reward over time (mitigates MEV race).
- Mode Static support.
- Active-bin opt-in deposits.
- Multi-bin-width modes within one deployment.
- Cross-pool LP NFTs (one NFT spanning multiple hook deployments).
- Governance / upgradeability layer.
- LP migration tooling for spec or implementation upgrades.
