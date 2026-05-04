# Security

Threat model and known limitations of the Directional Liquidity Hook.
Read alongside the spec's §7 (it's the source of truth) and the
hook-specific items below.

## Audit status

**Unaudited.** Do not use with production funds.

## Trust surface

The hook trusts:

- The configured **PoolManager** (immutable at deploy).
- v4's **Hooks** library short-circuiting self-calls during the hook's
  own `modifyLiquidity` calls.
- The two ERC-20 currencies (or native ETH) of the configured pool.
  Tokens that lie about `transfer`/`transferFrom` success would steal
  funds; this is the same trust assumption v4 itself makes.

The hook does NOT trust:

- The address that calls `deposit` / `withdraw` / `rebalance`. They are
  permissionless.
- LP NFT recipients — the recipient address is decoupled from the payer.
- Anything in the calldata to `unlockCallback`. The action id is
  validated; the inner payload is `bytes` decoded into typed structs that
  were originally encoded by the hook itself in the `deposit` / `withdraw`
  / `rebalance` entry points.

## What's intentionally absent

- **No admin.** No address can pause, upgrade, drain, or reconfigure the
  hook. All parameters are constructor immutables.
- **No upgrade path.** A bug in deployed bytecode requires a new
  deployment and LP-side migration.
- **No emergency stop.** If a swap-driven `_afterSwap` were to revert,
  swaps on the underlying v4 pool would also revert. Today `_afterSwap`
  only writes to the TWAP buffer; it cannot revert under expected
  conditions. Worth verifying whenever this code is touched.

## Known issues, accepted

### Keeper-reward MEV race (spec §7.3)

The keeper reward (5% of fees by default) is paid to whoever calls
`rebalance()` first after a trigger fires. This is a permissionless MEV
race. Front-running keepers will compete for the reward. We accept this
in v1; possible mitigations (decaying reward, rate-limited rebalance,
keeper allow-lists) are noted as future work.

Keeper rewards use a **pull-pattern**: `rebalance()` credits an internal
`_keeperOwed{0,1}[keeper]` escrow, and the keeper claims via a
separate `claimKeeperReward(to)` call. This isolates a malicious
keeper contract — whose `receive`/`fallback` reverts on incoming
native ETH — from being able to DoS the rebalance flow for other
keepers. See `docs/self-audit.md` finding F-4 and the test
`test_native_maliciousKeeperCannotDosRebalance` for the property
this defends.

### First-deposit tick manipulation (spec §7.4)

The first deposit into a mode reads the pool's spot tick (not TWAP) to
place the initial position. An attacker could:

1. Initialize a fresh pool at a manipulated tick.
2. Be the first depositor, locking the mode's initial position there.
3. Move the pool back; the mode's position is in the wrong range.

Mitigation: deploy hooks against pools with non-trivial trading history
before significant deposits arrive. Worth flagging in any front-end.

### Low-volume TWAP degradation (spec §4)

If no swap happens for longer than `twapWindow`, `getTwap()` returns the
most recent observation's tick. Same behavior as v3's oracle. Modes
respond slowly when activity resumes. Accepted limitation of any
swap-driven TWAP design.

### Multi-bin TWAP jumps (spec §7.7)

If TWAP jumps multiple bins between rebalances, the mode shifts
directly to the bin one behind current TWAP — no intermediate hops. LPs
do not earn fees retroactively for bins they were not in. This is an
explicit cost of slow keeping.

### Mode Both pays for ~2× more rebalances (spec §7.10)

Mode Both rebalances on either-direction TWAP exits, so it shifts
roughly twice as often as Right or Left. Keeper rewards come out of
fees, so Mode-Both LPs effectively pay more for rebalancing.
Documented in the LP guide.

## Hook-specific defenses

### PoolKey / PoolManager validation

Every callback (`afterSwap`, `beforeAddLiquidity`,
`beforeRemoveLiquidity`, `unlockCallback`) verifies:

- `msg.sender == address(poolManager)` (BaseHook's `onlyPoolManager`
  modifier; replicated explicitly in `unlockCallback`).
- The incoming `PoolKey` matches the immutable `poolId` (via
  `_requireOurPool`).

Combined, these reject any callback from anyone but the configured
manager and any callback for any pool other than the deployed-for one.

### Reentrancy

External entry points (`deposit`, `withdraw`, `rebalance`) use
`ReentrancyGuard`. The unlock callback re-enters the hook within a
single transaction (PoolManager → hook → modifyLiquidity → ... → return),
which is inside the same `entered` window — so any *external*
re-entry attempt (e.g. via a malicious token's `transferFrom`) is
rejected, while v4's own callback flow proceeds.

### LP NFT mint uses `_mint`, not `_safeMint`

`_safeMint` calls `onERC721Received` on contract recipients, which is a
reentry surface. `_mint` skips that. We're inside an `unlock` callback
during deposit, so `_safeMint` would compound the reentry exposure.
(Spec §7.9 default — we explicitly chose this default.)

### JIT-deposit attack

Prevented by the accumulator pattern: a depositor's `feeSnapshot` is
taken at deposit time *after* any pending fees are accrued. They cannot
claim fees from before they joined. Tested at the math layer in
`test/ShareMath.t.sol::test_pending_lateJoinerCannotClaimPreFees` and
end-to-end (with real swap-generated fees) in
`test/DirectionalLiquidityHookFees.t.sol::test_fees_jitAttackerGetsNothing`.

### Direct `modifyLiquidity` blocked

The hook reserves `beforeAddLiquidity` and `beforeRemoveLiquidity`. Any
external attempt to add/remove liquidity directly on the underlying v4
pool reverts with `DirectLiquidityModificationDisabled`. The hook
itself bypasses these guards via v4's `Hooks` library `noSelfCall`
short-circuit. Tested in
`test/DirectionalLiquidityHook.t.sol::test_deposit_directModifyLiquidityIsBlocked`.

### Last-LP cleanup

When the last LP exits a mode, all per-mode state is `delete`d
(accumulator zeroed, range zeroed, `initialized = false`). The next
deposit re-runs the lazy-init path. Tested in
`test/DirectionalLiquidityHook.t.sol::test_withdraw_thenRedeposit_reInitializesMode`.

### Single-currency rebalance invariant

Mode positions are always single-sided. The reverse-and-remint flow
relies on swap-through having already converted the burned position's
holdings into the currency the new range expects. If this invariant
were ever broken (a future v4 change in fee-collection ordering, or a
geometric edge case we missed), `_liquidityForSingleSidedRange` reverts
`UnexpectedPositiveDelta` rather than silently mis-mint at the new
range. Reviewers: any change to mode geometry must re-prove this
invariant.

### Mode-Both reversal — covered end-to-end

The Mode-Both reversal trigger is unit-tested at the geometry layer
(`test/ModeRange.t.sol::test_nextTarget_modeBothReversalFlipsDir`) and
end-to-end (real swap drives price across the position and out the
other side) in
`test/DirectionalLiquidityHook.t.sol::test_swapDriven_modeBoth_reversalEndToEnd`.
Reviewers should still focus extra attention on the `currentDir` flip
and `_remintAtNewRange`'s single-sided currency selection — the test
covers the canonical reversal but not all possible price paths.

## Reporting

Open an issue or contact the maintainer (via the repo). For security-
sensitive disclosures, prefer a private channel before opening a public
issue.
