# Uniswap v4 Hooks Security Deep Dive (Cyfrin)

> **Source**: https://www.cyfrin.io/blog/uniswap-v4-hooks-security-deep-dive
> **Author**: Cyfrin
> Compiled from public audit findings of v4 hook implementations.

This article categorizes vulnerabilities found in real audit reports of v4 hooks. It frames hooks as either **"benign but vulnerable"** or **"intentionally malicious"** — the article focuses on the former.

## Custom accounting is the highest-stakes category

Hooks with `*ReturnDelta` permissions take control of underlying liquidity. Bugs in these — or in any related contract that handles ERC-6909 claim tokens — are likely **catastrophic**. Auditors and developers should be paranoid about every source and sink of value.

Insufficient input validation is often the precursor to high-severity exploits. More complex hook architecture means more places where attacker-controlled inputs can break accounting.

## Pool key validation is critical

Hook functions should only grant permissioned access to the **specific subset of pools** they're intended to serve. Certora's 2024 review of the Doppler protocol uncovered a critical (C-01) where the victim contract — meant to coordinate ecosystem hooks — could be drained because a malicious pool key with attacker-controlled hook and currency addresses bypassed validation.

**Heuristic**: Are the `PoolKey` and associated `Currency` addresses validated to ensure permissioned access is granted only to the expected pools? If a hook supports multiple pools, is there an allowlist or registration step?

## Restrict callback callers

Like flash-loan callbacks, the v4 `unlockCallback` and hook callbacks should generally only be callable by the singleton `PoolManager`. Forgetting this check is a recurring vulnerability:

```solidity
// In any hook callback or unlockCallback:
require(msg.sender == address(poolManager), "Unauthorized");
```

`BaseHook` handles this for the standard `IHooks` functions, but if you expose any auxiliary external function that touches hook state, you must add the check yourself.

## Don't forget what's still exposed on PoolManager

When focused on a hook's logic, it's easy to forget the entry points that exist on `PoolManager` itself. Even with all hook permissions correctly encoded, you may have **unimplemented functions that should have been implemented** (with permissions set accordingly).

Example: a builder intends liquidity modifications to flow exclusively through their hook contract. But unless `beforeAddLiquidity` / `beforeRemoveLiquidity` are implemented to revert when called outside the expected flow, users can call `PoolManager.modifyLiquidity` directly and bypass the hook's intended logic.

**Heuristic**: For each pool action, ask "should this be allowed to flow through PoolManager directly, or only through my hook?" If only through your hook, implement the corresponding `before*` callback to enforce that.

## State management for multi-pool hooks

A hook serving multiple pools must:
- Key all per-pool state by `PoolId`, never global
- Prevent state from one pool affecting another
- Consider whether token registration / approval lists are per-pool or global

## Reentrancy

The introduction of hooks reintroduces reentrancy risk that was largely solved in v2/v3 core contracts. Any external call from inside a hook callback — to an oracle, an ERC-20, a separate strategy contract — is a potential reentrancy vector. Update state **before** external calls.

## Token assumption failures

An attacker can create a pool with a malicious or non-standard ERC-20 to exploit assumptions in a hook's logic:
- Fee-on-transfer tokens break "amount sent equals amount received"
- Rebasing tokens silently change balances
- ERC-777 / hooks on transfer enable reentrancy
- Tokens that don't return bool from `transfer` cause `SafeERC20`-less code to misbehave

If your hook is permissioned to only certain tokens, validate them on pool initialization.
