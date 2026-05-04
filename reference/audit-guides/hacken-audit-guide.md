# Auditing Uniswap V4 Hooks (Hacken)

> **Source**: https://hacken.io/discover/auditing-uniswap-v4-hooks/
> **Author**: Hacken

A structured walkthrough of how to audit a v4 hook, from initial configuration checks to advanced threats.

## The expanded attack surface

Hooks dramatically expand the attack surface vs. v2/v3. A single misconfigured or malicious hook can cause:
- Significant financial losses
- Denial-of-service conditions
- Pool state manipulation
- Privilege escalation

## Configuration checks (first step in any audit)

A misconfigured hook may revert all transactions on the pool due to:
- Wrong return values from callbacks (must return the correct selector)
- Return value type/size mismatches
- Permission bitmap not matching `getHookPermissions()`
- `*ReturnDelta` flag enabled without parent flag

The PoolManager interaction with a hook before a swap follows a specific sequence — any misconfiguration in this flow leads to unexpected behavior or transaction failures.

## Authorization vulnerabilities

**Weak permissions are the #1 issue.** Look for:
- External callable functions that touch hook state without `onlyPoolManager` check
- Functions that allow unauthorized hook modification (config, fee tiers, allowlists)
- Privileged roles that can change critical parameters with no timelock

To prevent this category: **all hook callbacks must restrict access to the PoolManager**. Any auxiliary external functions must have explicit access control.

## Centralization & governance risks

Since hooks are external contracts, they may be:
- **Upgradeable** (UUPS, transparent proxy) — logic can be modified post-deploy
- **Centrally controlled** — single owner or admin can pause, change parameters, or extract value
- **Granted privileged roles** — for fee adjustment, pool registration, etc.

Critical question: if a hook inherits from `UUPSUpgradeable`, what stops the upgrade authority from injecting a malicious withdrawal function later? An audited hook with an unsecured upgrade key is still a centralized custodian.

**Mitigations**:
- Multisig or DAO control over upgrade authority
- Timelock on upgrades and parameter changes
- Make the hook immutable for high-TVL or low-trust deployments
- Document trust assumptions clearly to users

## Multi-pool hook risks

Uniswap V4 allows multiple pools to reference the same hook. The `PoolManager.initialize` function does **not enforce exclusivity** — the same hook can be attached to many pools.

This creates risks:
- An attacker creates a malicious pool referencing your hook to exploit its logic
- Cross-pool state contamination if state isn't keyed by `PoolId`
- Trust assumptions valid for "blessed" pools may not hold for attacker-created pools

**Mitigation**: implement `beforeInitialize` to gate which pools can use the hook. Alternatively, accept that any pool can use the hook and design accordingly (no privileged pool, all state per-PoolId).

## Auditor checklist (high level)

1. **Configuration**: Permission bitmap, return values, address-to-permissions correctness
2. **Authorization**: `onlyPoolManager` on all entry points; no orphan external functions
3. **Reentrancy**: Guards on every callback that makes external calls
4. **State isolation**: Per-`PoolId` keying of all variable state
5. **Input validation**: `PoolKey` parameters validated, especially `currency0`/`currency1`/`hooks` fields
6. **Centralization**: Upgrade paths, owner roles, parameter authority
7. **Token compatibility**: Behavior with fee-on-transfer, rebasing, non-standard tokens
8. **Front-running**: Especially for hooks that adjust fees or accept user-provided data
9. **DoS vectors**: Unbounded loops, expensive operations, revert-by-design surfaces
10. **Economic soundness**: Game-theoretic analysis of incentive hooks, custom curves, dynamic fees
