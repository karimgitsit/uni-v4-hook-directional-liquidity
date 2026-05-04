# Self-audit report — DirectionalLiquidityHook

This is a self-audit pass against `reference/audit-guides/security-framework.md`,
with cross-references against the four supporting guides
(`certik-considerations.md`, `certora-best-practices.md`,
`cyfrin-deep-dive.md`, `hacken-audit-guide.md`). Each item is marked
**Covered** (test/code reference), **N/A** (with one-line rationale), or
**Gap** (severity guess + follow-up).

The hook's intentional design constraints — no upgradeability, no
privileged roles, one pool per hook, ERC721 LP NFTs, accumulator-based
fees — turn many classic findings into N/A. Those are noted to make the
posture explicit, not as filler.

This report is **not a substitute for a third-party audit**; it is a
structured walk-through to surface known gaps before external review.

---

## 1. Universal best-practices checklist

### 1.1 Access control

- **All callbacks revert when `msg.sender != address(poolManager)`** —
  Covered. `BaseHook` enforces this for `_afterSwap`, `_beforeAddLiquidity`,
  `_beforeRemoveLiquidity`. `unlockCallback` re-checks explicitly
  (`if (msg.sender != address(poolManager)) revert NotPoolManagerUnlock();`).
  Adversarial test:
  [DirectionalLiquidityHook.t.sol:451](test/DirectionalLiquidityHook.t.sol:451)
  (deposit), :719 (rebalance), :314 (afterSwap).
- **No functions accept arbitrary `PoolKey` from untrusted callers
  without validation** — Covered. Every callback that takes a `PoolKey`
  routes through `_requireOurPool(key)`
  ([src/DirectionalLiquidityHook.sol:1138](src/DirectionalLiquidityHook.sol:1138))
  which compares `PoolId.unwrap(key.toId())` against the immutable
  `poolId`.
- **Privileged roles use multisig/timelock, not EOA** — N/A. No
  privileged roles exist; all parameters are constructor immutables.

### 1.2 Reentrancy

- **No external calls to untrusted contracts before state updates** —
  Covered. The hook only calls (a) PoolManager, (b) the two configured
  ERC20s, (c) ERC-721 mint/burn (no external callback because we use
  `_mint`, not `_safeMint`). All "external" calls have a defined,
  audited counterparty.
- **`ReentrancyGuard` on functions that can be re-entered** — Covered.
  `deposit`, `withdraw`, `rebalance` all carry `nonReentrant`. The
  `unlockCallback` deliberately omits the modifier — re-entry via
  PoolManager during the same `entered` window is the correct flow and
  must not revert. Effective re-entry from a malicious token's
  `transferFrom` would attempt to call back into one of the three
  external entry points, which the guard blocks.
- **Aware of the asymmetric self-call exemption** — Covered. The
  `_beforeAddLiquidity` / `_beforeRemoveLiquidity` reverts only fire on
  external callers; v4's `Hooks` library short-circuits self-calls so
  the hook can `modifyLiquidity` on its own positions without
  self-locking. Documented in
  [SECURITY.md](SECURITY.md) § "Direct modifyLiquidity blocked" and at
  [src/DirectionalLiquidityHook.sol:498](src/DirectionalLiquidityHook.sol:498).

### 1.3 Pool isolation

- **All per-pool state keyed by `PoolId`, never global** — N/A. One
  hook contract per pool by design; `poolKey`/`poolId` are immutable.
  Per-mode state (`_modes[m]`) is keyed by mode id, but `m ∈ [0,3)` is
  bounded and not pool-derived. The choice is documented in
  [CLAUDE.md](CLAUDE.md) (§ "Code conventions") and enforced at the
  callback boundary by `_requireOurPool`.
- **PoolKey validation against allowed set** — Covered (single key).
  `_requireOurPool` rejects any other key.
- **No assumption hook serves only one pool unless enforced** — Covered
  by `_requireOurPool` + immutable `poolId` + constructor's
  `address(poolKey_.hooks) == address(this)` guard.

### 1.4 Token handling

- **No assumption that ERC-20 `transfer` returns true** — Covered.
  `_settleFromPayer` and `_settleFromHook` use `call` and check both
  `ok` and `(ret.length == 0 || abi.decode(ret,(bool)))`, the standard
  SafeERC20 idiom
  ([src/DirectionalLiquidityHook.sol:932](src/DirectionalLiquidityHook.sol:932),
  :971). Outbound transfers to LPs/keepers go through v4's
  `CurrencyLibrary.transfer`, which handles non-standard return data.
- **Native ETH handling: check `currency.isAddressZero()` before ERC-20
  methods** — Covered.
  [DirectionalLiquidityHookNative.t.sol](test/DirectionalLiquidityHookNative.t.sol)
  exercises every native branch end-to-end (deposit, withdraw to a
  contract recipient, keeper rebalance reward, underpaid `msg.value`
  graceful failure). The `receive() external payable` added at
  [src/DirectionalLiquidityHook.sol:344](src/DirectionalLiquidityHook.sol:344)
  is required because v4's `Currency.transfer` for native uses raw
  `call{value:}` with empty data — without it, `manager.take(ADDRESS_ZERO,
  hook, ...)` would revert.
- **Fee-on-transfer tokens** — Gap (Low). The hook does not detect
  fee-on-transfer tokens. v4's `sync()`/`settle()` flow uses balance
  deltas, so a fee-on-transfer token would cause `settle` to short the
  pool and the deposit to revert. **Mode of failure is graceful (revert,
  not silent loss)** but worth documenting on a deployer-facing list of
  unsupported token classes. Follow-up: add an explicit warning to
  [README.md](README.md) and (optionally) test a mock fee-on-transfer
  token to confirm the revert path.
- **Rebasing tokens** — Gap (Low). Same posture as fee-on-transfer:
  silent balance changes between observations would distort accumulator
  arithmetic. The hook holds others' fees as ERC20 balance, so a rebase
  in either direction silently inflates/deflates owed-fee precision.
  Same follow-up as fee-on-transfer.

### 1.5 Custom accounting

- **Every `*ReturnDelta` flag justified** — N/A. The hook enables
  none of the `*ReturnDelta` permissions
  ([test/DirectionalLiquidityHook.t.sol:1137](test/DirectionalLiquidityHook.t.sol:1137)
  asserts the exact set, including all the `false`s).
- **Sign and direction of every delta documented and tested** —
  Covered. `_doDeposit`, `_doWithdraw`, `_burnOldPosition`,
  `_remintAtNewRange`, and `_liquidityForSingleSidedRange` all have
  explicit sign-and-direction comments. Defensive reverts
  (`UnexpectedPositiveDelta`, `UnexpectedNegativePrincipal`) catch any
  invariant break.
- **Fuzz tests cover input space** — Covered.
  [DirectionalLiquidityHookInvariants.t.sol](test/DirectionalLiquidityHookInvariants.t.sol)
  runs 256 × 64 stateful sequences with bounded random
  deposit/withdraw/swap/rebalance calls. Pure-math fuzz at
  [test/ShareMath.t.sol](test/ShareMath.t.sol).

### 1.6 Deployment

- **CREATE2 salt mining is reproducible and tested** — Covered.
  [script/DeployDirectionalLiquidityHook.s.sol](script/DeployDirectionalLiquidityHook.s.sol)
  uses `HookMiner.find` with the canonical CREATE2 deployer proxy. The
  loop iterates twice to resolve the fixed point between mined address
  and embedded `pkProbe.hooks`. The address-bit assertion lives in the
  test harness
  ([test/DirectionalLiquidityHook.t.sol:165](test/DirectionalLiquidityHook.t.sol:165)).
- **Deployment script asserts `address(hook) == predictedAddress`** —
  Covered.
  [script/DeployDirectionalLiquidityHook.s.sol:137](script/DeployDirectionalLiquidityHook.s.sol:137)
  has `require(address(hook) == hookAddr, "deployed address mismatch")`.
- **Permission bitmap derived from address matches `getHookPermissions()`**
  — Covered. Test asserts this directly
  ([test/DirectionalLiquidityHook.t.sol:165](test/DirectionalLiquidityHook.t.sol:165))
  and the script's `expectedFlags()` is `pure` so the mining input is
  decoupled from the contract logic but provably equal at compile time.
- **Salt-mining loop convergence guarantee** — Gap (Low). The mining
  loop in `_mineForFlags` runs at most 2 iterations. If the fixed point
  doesn't converge in that many passes (rare in practice — mining is
  deterministic and the address space is dense enough that two passes
  are usually sufficient), the deployment proceeds with an inconsistent
  embedded `hooks` field and the constructor reverts with `"PoolKey
  hook != this"`. Failure mode is **graceful** (deploy aborts before
  any state is created), but the deployer is left without a clear
  diagnostic. Follow-up: bump the loop bound to e.g. 5 and revert with
  a named error if not converged.

---

## 2. Seven risk dimensions

### 2.1 Accounting risk

- Hook is custodial (holds ERC20/ETH between `take` and the next
  `transfer`).
- Source/sink list:
  - **In** — depositor → manager → (burn) → hook (during rebalance/
    withdraw via `take`).
  - **Out** — hook → manager (during deposit `settle`) → LP (withdraw
    payout) → keeper (rebalance reward).
- Every source/sink pair is covered by:
  - Pure-math tests
    ([test/ShareMath.t.sol](test/ShareMath.t.sol))
  - Swap-driven end-to-end tests
    ([test/DirectionalLiquidityHookFees.t.sol](test/DirectionalLiquidityHookFees.t.sol))
  - Invariant: hook ERC20 balance ≥ Σ unclaimed LP fees
    ([test/DirectionalLiquidityHookInvariants.t.sol:115](test/DirectionalLiquidityHookInvariants.t.sol:115))
- Rounding: `sharesForDeposit` and `liquidityForWithdraw` round down,
  `accrueFeePerShare` uses Q128 fixed-point. Withdraw rounding leaves
  dust in the hook, never under-pays the LP. Tests tolerate ≤ 5 wei
  rounding on round-trip assertions.
- Status: Covered.

### 2.2 Math & curve correctness

- The hook does NOT implement a custom curve; it routes liquidity into
  v4's standard concentrated-liquidity curve via `modifyLiquidity`.
- Mode geometry (`ModeRange`) is pure and unit-tested in
  [test/ModeRange.t.sol](test/ModeRange.t.sol).
- Edge cases tested: empty modes (last-LP cleanup), bin alignment
  near `tick = 0`, near-zero liquidity (deposit minimum), cross-bin
  TWAP jumps, same-bin no-op shortcut.
- Status: Covered.

### 2.3 External dependencies

- **Oracle feeds** — N/A. No external oracle; TWAP is internal,
  swap-driven, and the source is the same pool the hook serves
  (manipulating it requires being the swap counterparty).
- **External contract calls** — Limited to PoolManager + the two
  configured ERC20s + native ETH transfers. No registry, no allowlist,
  no off-chain feed.
- **Token assumptions** — fee-on-transfer / rebasing flagged as gaps
  in §1.4.
- **ERC-777 / re-entry hooks on transfer** — Gap (Informational). The
  hook does not blacklist ERC-777 currencies. The pool's currency
  pair is fixed at deploy, so this is a deploy-time choice; document
  in the deployer guide.
- Status: Covered with documented limitations.

### 2.4 Governance & upgradeability

- **Upgradeability** — N/A. No proxy. Bytecode is immutable post-deploy.
- **Privileged roles** — N/A. No admin / owner / pauser / fee
  recipient. All parameters constructor-immutable.
- Documented as a feature, not a missing capability, in
  [SECURITY.md](SECURITY.md) § "What's intentionally absent".
- Status: N/A by design.

### 2.5 Liquidity behavior

- **Can the hook brick liquidity withdrawals?** — No external state
  blocks `withdraw`. The only failure modes are (a) caller is not the
  NFT owner / approved (`NotPositionOwner`) and (b) v4's `take`
  reverts (which would mean the underlying pool itself is broken —
  out of scope).
- **LP exit paths** — Withdrawal works during stale rebalance state
  (returns the stale currency mix; LP can self-rebalance first if
  desired). Tested:
  [test/DirectionalLiquidityHook.t.sol:533](test/DirectionalLiquidityHook.t.sol:533).
- **Asymmetric callback logic** — `_beforeAddLiquidity`/
  `_beforeRemoveLiquidity` revert externally, allow internally — by
  design. Tested:
  [test/DirectionalLiquidityHook.t.sol:727](test/DirectionalLiquidityHook.t.sol:727)
  and :740.
- Status: Covered.

### 2.6 Address-encoded permissions

- Permission bits asserted at deploy time, in the test harness, and in
  the deploy script. See §1.6 above.
- `getHookPermissions()` is `pure` and the test
  [test/DirectionalLiquidityHook.t.sol:1137](test/DirectionalLiquidityHook.t.sol:1137)
  exhaustively confirms all 14 bits.
- Status: Covered.

### 2.7 Routing & cross-chain risks

- **Hook may be invoked multiple times in one tx** — the only hook
  callback enabled per-swap is `_afterSwap`, which is idempotent
  beyond writing one observation per call. Multi-hop routing through
  the same pool would write multiple observations within the same
  block; the same-second overwrite branch
  ([src/DirectionalLiquidityHook.sol:1162](src/DirectionalLiquidityHook.sol:1162))
  collapses them into a single observation. Tested:
  [test/DirectionalLiquidityHook.t.sol:260](test/DirectionalLiquidityHook.t.sol:260).
- **Cross-chain** — N/A. Single-chain hook, no bridge or message
  passing.
- Status: Covered.

---

## 3. Common failure modes (`security-framework.md` table)

| Pattern | Status | Notes |
|---|---|---|
| Missing `onlyPoolManager` on auxiliary functions | Covered | `BaseHook` + explicit re-check on `unlockCallback`. |
| Global state instead of per-`PoolId` | N/A | One pool per hook deployment. |
| Trusting an arbitrary `PoolKey` | Covered | `_requireOurPool`. |
| Unbounded loops in callbacks | Covered | Only loops are `MODE_COUNT = 3` and the TWAP buffer walk (≤ `bufferSize`). Both bounded by immutables. |
| Custom accounting math errors | Covered | Pure-math fuzz + invariant fuzz. Q128 fee scaling. |
| Hook calls untrusted contract mid-callback | Covered | Only PoolManager + configured currencies. No registry/allowlist. |
| Forgetting that hooks can be called multiple times in one tx | Covered | `_afterSwap` idempotent; multi-mode `rebalance` already batches in one unlock. |
| Wrong CREATE2 salt | Mostly covered | See §1.6 gap on convergence iterations. |

---

## 4. Hook-specific items

### 4.1 Spec §11 open questions

- **§11.1 `_mint` vs `_safeMint`** — Resolved at code level (`_mint`)
  to avoid the ERC-721 `onERC721Received` reentry surface during the
  open `unlock` window. Still listed as "open" in the spec; the code
  decision is final unless an integrator surfaces a need. Documented
  inline at
  [src/DirectionalLiquidityHook.sol:671](src/DirectionalLiquidityHook.sol:671).
- **§11.2 buffer-warmup on first deposit** — Resolved (default to spot
  tick). Tested:
  [test/DirectionalLiquidityHook.t.sol:824](test/DirectionalLiquidityHook.t.sol:824).
  Trade-off (first-deposit tick manipulation) acknowledged in §7.4 of
  the spec and mirrored in
  [SECURITY.md](SECURITY.md) § "First-deposit tick manipulation".
- **§11.3 default `bufferSize`** — Open. Constructor enforces
  `bufferSize >= 8` (`MIN_BUFFER_SIZE`); the deploy script logs a
  per-chain coverage table to help operators choose. Status: Gap
  (Informational) — pick a recommended default in the README before
  mainnet.
- **§11.4 zero-fee continuation** — Resolved (rebalance proceeds even
  with zero fees). Tested:
  [test/DirectionalLiquidityHook.t.sol:767](test/DirectionalLiquidityHook.t.sol:767).

### 4.2 Native-ETH residual

- **No refund on overpaid `msg.value`** — Gap (Low). If a depositor
  sends `msg.value > amount0_needed`, the hook silently retains the
  excess in its native balance with no withdrawal path
  (`receive` accepts blindly; no admin to recover). Failure mode is
  user-side overpayment leading to permanent loss. Follow-up: refund
  the residual at the end of `deposit` via
  `payable(msg.sender).call{value: address(this).balance}("")` (with
  ReentrancyGuard already active) or revert if `msg.value !=
  needed`. Either is a tightening; current behavior is honest but
  unfriendly.

### 4.3 Keeper-reward path

- **Keeper is a malicious contract that reverts on receive** — Gap
  (Low). `_doRebalance`'s end-of-loop `currency.transfer(keeper, ...)`
  uses raw `call{value:}` for native; if the keeper is a contract
  whose `receive`/`fallback` reverts, the entire rebalance reverts —
  bricking the rebalance until a different keeper calls. This is
  effectively a self-DoS by the malicious keeper (they pay gas to
  prevent themselves from being paid), so the economic incentive
  argues against exploitation at scale. Documented as MEV-class risk
  in
  [SECURITY.md](SECURITY.md) § "Keeper-reward MEV race"; could be
  hardened by switching to a pull-pattern (`unclaimedKeeperReward`
  mapping with a separate `claimReward` call).

### 4.4 ETH dust accumulation in the hook

- The hook's new `receive() external payable {}` accepts any caller's
  ETH. With no admin path, accidentally-sent ETH becomes permanent
  hook balance. This dust does NOT corrupt accounting (the
  invariant tests show hook balance ≥ owed; surplus is fine). It
  does affect the §4.2 finding (overpayment becomes lost). Note in
  the deployer guide.

### 4.5 ERC-721 transfer of LP NFT mid-cycle

- The LP NFT can be transferred by the owner at any time. The new
  owner becomes the LP and can `withdraw`. No callback during
  transfer (`_mint`/`_burn` only; standard `transferFrom` doesn't
  fire ERC-721 receive hooks). No re-entry risk; no special handling
  needed.
- Status: Covered by design.

### 4.6 Constructor input bounds

- `binWidth > 0`, `twapWindow > 0`, `keeperRewardBps <= 10_000`,
  `bufferSize >= MIN_BUFFER_SIZE`, `tickSpacing > 0`, `binWidth ×
  tickSpacing <= MAX_BIN_TICKS`. Each enforced at construction.
  Adversarial cases tested:
  [test/DirectionalLiquidityHook.t.sol:123](test/DirectionalLiquidityHook.t.sol:123)
  (tiny buffer), :143 (oversized binTicks).
- One subtle case: `keeperRewardBps == 10_000` is allowed and would
  send 100% of fees to the keeper, leaving LPs with zero fee accrual.
  Currently undocumented but not forbidden by spec. Status: Gap
  (Informational) — add a sanity bound to README, or leave as-is for
  flexibility.

### 4.7 PoolManager binding is unverified

- The constructor accepts any `IPoolManager` address — there is no
  on-chain check that the address is a real, audited v4 PoolManager.
  A deployer who passes a malicious manager wires every flow through
  attacker-controlled code. By design — the hook is for a single
  pool the deployer chose, including the manager — but an integrator
  reading the deploy script should validate manager identity
  off-chain (chain-id + canonical address).
- Status: N/A by design. Documented implicitly via the trust statement
  in [SECURITY.md](SECURITY.md) § "Trust surface".

---

## 5. Findings summary

Triage table — F-1 and F-7 remain open as documentation tasks; F-2
through F-6 closed in the follow-up pass.

| # | Severity | Item | Status |
|---|---|---|---|
| F-1 | Low | Fee-on-transfer / rebasing token compatibility (§1.4) | Open — document |
| F-2 | Low | Salt-mining loop convergence iteration cap (§1.6) | **Closed** — bumped loop to 8 iterations; reverts `MiningDidNotConverge` if exceeded |
| F-3 | Low | Native ETH overpayment is silently retained (§4.2) | **Closed** — `deposit` refunds `msg.value − nativeSpent` to the payer; reverts `RefundFailed` on contract payers that reject ETH |
| F-4 | Low | Malicious keeper contract can DoS rebalance (§4.3) | **Closed** — keeper rewards now use a pull-pattern (`claimKeeperReward`); rebalance only credits an escrow mapping, never sends inline |
| F-5 | Info | `bufferSize` default not pinned (§4.1) | **Closed** — per-chain table added to README |
| F-6 | Info | `keeperRewardBps == 10_000` allowed (§4.6) | **Closed** — README explicit warning |
| F-7 | Info | ERC-777 / non-standard token currencies (§2.3) | Open — deployer guide |

Each item links back to the section in this report that describes the
finding, the implementation that closed it (when applicable), and the
code/test references.

### Tests covering the closed findings

- F-3: [test_native_overpaidDepositRefundsExcess](test/DirectionalLiquidityHookNative.t.sol),
  [test_native_overpaidDepositReverts_whenPayerRejectsRefund](test/DirectionalLiquidityHookNative.t.sol),
  [test_native_exactPaymentRequiresNoRefund](test/DirectionalLiquidityHookNative.t.sol).
- F-4: [test_native_maliciousKeeperCannotDosRebalance](test/DirectionalLiquidityHookNative.t.sol)
  + the existing [test_fees_keeperGetsConfiguredCutOnRebalance](test/DirectionalLiquidityHookFees.t.sol)
  updated to exercise the claim path.

## 6. Out-of-scope for this pass

- Gas-griefing analysis under realistic L2 swap volumes.
- Formal verification (Certora rules — flagged as future work in spec
  § 12).
- Differential testing vs. a Maverick reference implementation (none
  exists in v4 form — this hook IS the port).
- Static analysis run (Slither / Aderyn). Recommended as the next
  defensive pass before audit.
