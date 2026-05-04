# Best Practices for Writing Secure Uniswap v4 Hooks (Certora)

> **Source**: https://www.certora.com/blog/best-practices-for-writing-secure-uniswap-v4-hooks
> **Author**: Certora

Practical guidance on writing hooks that are robust, efficient, and resistant to attacks.

## What hooks let you do (and where it goes wrong)

Hooks customize core operations by executing logic before or after pool actions:
- `beforeAddLiquidity`, `beforeRemoveLiquidity`, `afterAddLiquidity`, `afterRemoveLiquidity` — modify liquidity provisioning
- `afterSwap` hooks can redistribute currency deltas (virtual balances)
- These enable dynamic fees, on-chain limit orders, custom incentives

The flexibility introduces risk if implemented carelessly.

## Top risk: external calls during callbacks

Hooks can call external contracts, but this risks:
- **Reentrancy attacks**: Malicious contracts re-enter the PoolManager to manipulate currency deltas before settlement
- **Forced reverts**: Untrusted contracts intentionally revert, bricking transactions and trapping user funds

**Mitigations**:
- Use reentrancy guards (e.g., OpenZeppelin's `ReentrancyGuard`)
- Restrict interactions to audited, trusted contracts
- Avoid transferring control to untrusted addresses during critical operations
- Update internal state before any external call (CEI pattern)

## Top risk: input validation & cross-pool contamination

Hooks must validate inputs to prevent spoofing or cross-pool contamination.

A malicious actor could:
- **Spoof a pool key** — pass a `PoolKey` with arbitrary `currency0`/`currency1`/`hooks` fields to trick the hook into misallocating funds
- **Mix funds across pools** — use the same hook for multiple pools with overlapping state, causing one pool's funds to be debited from another

**Mitigations**:
- Enforce strict access control: `require(msg.sender == address(poolManager))`
- Validate all pool keys and parameters (token addresses, fee tiers)
- **Track all state by `PoolId`** to prevent cross-pool contamination

```solidity
// ✓ correct
mapping(PoolId => uint256) public balancePerPool;

// ✗ wrong — global state shared across all pools using this hook
uint256 public globalBalance;
```

## Self-call asymmetry

When hooks initiate `PoolManager` calls themselves (rather than being called externally), some permissioned callbacks are **skipped** for self-initiated operations but **trigger** for external callers.

This asymmetric behavior creates logic gaps where hooks assume certain validations or state updates occur during self-initiated operations, leaving the system vulnerable to manipulation.

**Mitigation**: never assume both code paths produce the same effect. Test self-initiated operations explicitly.

## Verification tooling

Before mainnet:
- **Static analysis**: Slither for common vulnerability patterns
- **Fuzz testing**: Echidna or Medusa for property-based testing across input space
- **Formal verification**: Certora Prover for critical components — accounting math, invariants, access control
- **Third-party audits**: at least one for any production hook; two independent audits for custodial or `*ReturnDelta` hooks

## Custom accounting needs extra care

Hooks that return deltas (modify accounting) are particularly powerful and dangerous:
- The math must be sound — rounding errors are exploitable at scale
- Document sign and direction of every delta value
- Property-based tests should fuzz across the full range of swap amounts and tick boundaries
- Watch for integer over/underflow even with Solidity 0.8+ checked arithmetic — explicit casts (`int128`, `int256`) bypass checks

## Six-line summary

1. `onlyPoolManager` on every entry point that touches state.
2. Validate the `PoolKey` if your hook is for specific pools.
3. Per-`PoolId` state, never global.
4. Reentrancy guards on callbacks that make external calls.
5. Be paranoid about token compatibility (fee-on-transfer, rebasing).
6. Fuzz everything that does math.
