# Project: Directional Liquidity Hook

A Uniswap v4 hook porting Maverick AMM's directional liquidity modes
(Mode Right, Mode Left, Mode Both). See `spec/DirectionalLiquidityHook-spec.md`
for the full design — that spec is authoritative.

## Authoritative reference order

When in doubt, consult in this order:

1. `spec/DirectionalLiquidityHook-spec.md` — design decisions for THIS hook.
2. `reference/v4-core-types/` and `reference/v4-hooks-base/` — v4 interfaces
   and types. These are the contract surface we build against.
3. `reference/example-hooks/` — patterns to study, especially
   `BaseCustomAccounting_sol.md` (hook owns positions),
   `LiquidityPenaltyHook_sol.md` (per-pool LP management),
   `LimitOrderHook_sol.md` (positions across rebalances).
4. `reference/audit-guides/` and `reference/project-conventions/` — security
   posture and house style.

If the spec contradicts a reference file, follow the spec — but flag the
contradiction so we can resolve it.

## Environment

- Solidity ^0.8.24
- Foundry (forge, anvil) — never suggest Hardhat unless asked
- Tests written in Solidity using forge-std
- Local anvil run with `--code-size-limit 30000`

## Code conventions

- Every hook inherits from `BaseHook` (v4-periphery/src/utils/BaseHook.sol)
- Always implement `getHookPermissions()` and return only the flags the hook
  actually uses — never enable a permission the hook doesn't need
- Use `_beforeSwap`, `_afterSwap`, etc. (the internal underscore-prefixed
  overrides from BaseHook), not the external IHooks functions directly
- State that varies per-pool must be keyed by `PoolId`, never global —
  though for THIS hook the pool is fixed at deployment so this rule is moot
  (one hook contract per pool, `PoolKey` immutable)
- Use named imports: `import {Foo} from "...";` — never `import "...";`

## Deployment

- Hook permissions are encoded in the deployed address — always use CREATE2
  with `HookMiner` to find a salt that produces the correct permission bits
- Provide a deployment script (`script/DeployDirectionalLiquidityHook.s.sol`)
- Test against a local anvil node with `--code-size-limit 30000`

## Testing

- Every hook gets a matching `<HookName>.t.sol` with at least:
  - initialization test
  - permission flag test
  - happy-path callback test
  - one adversarial test (wrong caller, malicious pool key, or reentrancy)
- Use the v4-template test fixtures (`deployFreshManagerAndRouters`, etc.)
- Spec §8 lists the full required test set for this hook.

## Security defaults

- Verify `msg.sender == address(poolManager)` on any externally-callable
  function that should only be called by the PoolManager
- Validate the `PoolKey` on every callback (this hook is for ONE specific
  pool, so the check is `incoming poolKey == immutable poolKey`)
- Treat any external call from within a hook as a reentrancy risk — use
  `ReentrancyGuard` or transient storage locks
- For hooks with custom accounting (returning deltas), be explicit about
  the sign and direction in comments
- Flag any upgradeability or privileged-role design as a security concern.
  This hook intentionally has neither — that is a design property to
  preserve, not a missing feature.

## Workflow

- Default to the simplest implementation that meets the spec; flag
  optimizations separately rather than baking them in upfront.
- Always show the `getHookPermissions()` return alongside the hook contract.
- After writing each component, list security considerations specific to
  that component.
- The spec has an "Open implementation questions" section (§11). When you
  hit one of those questions, default to the resolution noted there but
  flag the choice in your response so it can be reviewed.

## Build order suggestion

The spec is large. Suggested order to build incrementally:

1. **Skeleton.** Constructor, immutables, `getHookPermissions()`, empty
   external entry points (`deposit`, `withdraw`, `rebalance`), revert stubs
   for `_beforeAddLiquidity`/`_beforeRemoveLiquidity`, no-op `_afterSwap`.
   Plus init-only test.
2. **TWAP buffer.** Implement `_afterSwap` observation writes and
   `getTwap()` query. Test buffer wraparound and warmup.
3. **Mode state and accumulator math.** Per-mode storage layout, share
   accounting math (no v4 calls yet — pure functions tested in isolation).
4. **First-deposit path** for one mode (start with Mode Right). Lazy init,
   PoolManager `unlock` callback, NFT mint.
5. **Subsequent deposits + withdrawals** for that mode. Including
   last-LP cleanup.
6. **Rebalance** for one mode. Single-mode shift, keeper reward.
7. **Generalize to all three modes.** Mode Left mirrors Mode Right;
   Mode Both adds the bidirectional shift logic with `lastShiftDir`.
8. **Multi-mode batch rebalance** in one `unlock`.
9. **Deployment script** with HookMiner.
10. **Documentation pass** per spec §10.

Do not skip ahead. Each step should land with tests passing before moving on.
