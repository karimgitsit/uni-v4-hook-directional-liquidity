# Uniswap v4 Hooks — Security Framework

> **Source**: https://docs.uniswap.org/contracts/v4/security
> **Related framework**: https://github.com/uniswapfoundation/security-framework

This is a condensed reference of the official Uniswap Foundation Security Framework. It is **informational** — the Uniswap Foundation does not audit or certify hooks. Use at your own risk and always pair with a third-party audit before mainnet deployment.

## Why hooks are a new security category

Uniswap v4 shifts the security model from "trust one monolithic protocol" to a **shared responsibility model**. Hooks are arbitrary code that the PoolManager calls — they can:
- Hold user funds (custodial hooks)
- Modify swap accounting via delta returns
- Reject transactions (DoS users)
- Be upgradeable or governed (centralization risk)

These behaviors didn't exist in v2/v3. A hook bug can mean direct loss of user funds, even if the v4 core is bulletproof.

## The 7 risk dimensions

The framework evaluates hook risk across these dimensions:

### 1. Accounting risk
- Does the hook modify deltas (`*ReturnDelta` permissions)?
- Are there rounding errors that can be exploited at scale?
- Can a malicious caller submit inputs that drain liquidity?

**Mitigation**: extensive fuzz tests on accounting logic; track every source and sink of value; assume integer precision attacks are possible.

### 2. Math & curve correctness
- Custom curves (constant-product alternatives) must be mathematically sound.
- Test edge cases: empty pools, near-zero liquidity, max-tick prices.

### 3. External dependencies
- Oracle feeds → manipulation via low-liquidity pools or flash loans.
- External contract calls → reentrancy.
- Token assumptions → fee-on-transfer, rebasing, ERC-777 hooks can break invariants.

**Mitigation**: use `ReentrancyGuard` or transient locks; whitelist tokens; use TWAPs not spot prices for oracle feeds.

### 4. Governance & upgradeability
- Upgradeable hooks (UUPS, transparent proxy) can be modified post-audit.
- Privileged roles (owner, admin) introduce centralization risk.
- Timelocks and multisigs reduce but don't eliminate this risk.

**Mitigation**: be transparent about trust assumptions; prefer immutable hooks for high-TVL use cases; if upgradeable, document the upgrade authority and process.

### 5. Liquidity behavior
- Can the hook brick liquidity withdrawals?
- Are there conditions under which LPs cannot exit?
- Asymmetric callback logic (hooks behave differently when called by themselves vs. external callers) can create gaps.

### 6. Address-encoded permissions
- Hooks rely on a hashed permission system: PoolManager derives a 14-bit permission bitmap from the lowest bits of the hook's address.
- If CREATE2 salt is computed wrong, deployment will produce a hook with **incorrect permissions**.
- Permissions are immutable — wrong permissions mean redeployment.

**Mitigation**: verify expected permission bitmap in deployment pipeline; assert `address(deployedHook) == predictedAddress`; test that `getHookPermissions()` matches the address bits.

### 7. Routing & cross-chain risks
- Hooks may be invoked **multiple times in the same transaction** during multi-hop routing through aggregators. Test for this.
- Cross-chain-aware hooks face risks that don't exist in single-chain designs (replay, message ordering).

## The universal best-practices checklist

Apply these to every hook regardless of design:

### Access control
- [ ] All callbacks revert when `msg.sender != address(poolManager)` (BaseHook handles the IHooks functions; you must add this for any other external functions you expose)
- [ ] No functions accept arbitrary `PoolKey` from untrusted callers without validation
- [ ] Privileged roles use a multisig or timelock, not an EOA

### Reentrancy
- [ ] No external calls to untrusted contracts before state updates
- [ ] `ReentrancyGuard` or transient-storage locks on functions that can be re-entered
- [ ] Aware of the asymmetric self-call exemption: when a hook initiates a PoolManager call to itself, certain permission checks are skipped

### Pool isolation
- [ ] All per-pool state is keyed by `PoolId`, never global
- [ ] Validation that a given `PoolKey` belongs to the set the hook was designed for, if applicable
- [ ] No assumption that the hook only serves one pool unless explicitly enforced in `beforeInitialize`

### Token handling
- [ ] No assumption that ERC-20 `transfer` returns true — use SafeERC20
- [ ] Aware of fee-on-transfer tokens breaking accounting
- [ ] Aware of rebasing tokens
- [ ] Native ETH handling: check `currency.isAddressZero()` before calling ERC-20 methods

### Custom accounting
- [ ] Every `*ReturnDelta` flag is justified — if you don't need it, don't enable it
- [ ] Sign and direction of every delta is documented and tested
- [ ] Fuzz tests cover the full input space of swap amounts and tick boundaries

### Deployment
- [ ] CREATE2 salt mining is reproducible and tested
- [ ] Deployment script asserts `address(hook) == predictedAddress`
- [ ] Permission bitmap derived from address matches `getHookPermissions()` return value
- [ ] BUSL-1.1 license implications understood for production deployments

## Common failure modes (real audit findings)

| Pattern | What goes wrong |
|---|---|
| Missing `onlyPoolManager` on auxiliary functions | Anyone calls the hook directly, bypassing PoolManager checks (Cork Protocol incident) |
| Global state instead of per-PoolId | One pool's activity corrupts another's accounting |
| Trusting an arbitrary `PoolKey` parameter | Attacker passes a malicious pool key to drain victim contract (Doppler C-01) |
| Unbounded loops in callbacks | Gas-griefing DoS makes a pool unusable |
| Custom accounting math errors | Direct fund loss via rounding exploits |
| Hook calls external untrusted contract mid-callback | Reentrancy drain |
| Forgetting that hooks can be called multiple times in one tx | Routing attacks where state assumptions break |
| Wrong CREATE2 salt | Pool init reverts; if not caught in tests, mainnet deploy fails |

## When to audit

- **Before any mainnet deployment**, especially if the hook is custodial or returns deltas.
- Static analysis (Slither) + fuzzing (Echidna, Medusa) + formal verification (Certora) before audit.
- A hook with `*ReturnDelta` permissions or custodial behavior should generally have **two independent audits**.

## Further reading (linked in detail in `04-security/` files)

- Cyfrin: Uniswap v4 Hooks Security Deep Dive
- Hacken: Auditing Uniswap V4 Hooks
- Certora: Best Practices for Writing Secure Uniswap v4 Hooks
- CertiK: Uniswap V4 Hooks Security Considerations
- BlockSec: "Thorns in the Rose" threat model paper
