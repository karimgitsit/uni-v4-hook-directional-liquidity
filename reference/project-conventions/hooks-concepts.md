# Uniswap v4 Hooks — Concepts

> **Source**: https://docs.uniswap.org/contracts/v4/concepts/hooks
> **Related**: https://docs.uniswap.org/concepts/protocol/hooks

## What hooks are

Hooks are external smart contracts that can be attached to individual Uniswap v4 pools to intercept and modify the execution flow at specific points during pool-related actions. They are the defining feature of v4, distinguishing it from v2 and v3.

Each pool can have at most **one hook** specified at pool creation (in `PoolManager.initialize`). A single hook contract can serve **many pools** — there is no built-in restriction on how many pools reference the same hook.

Hooks are **optional**. A pool created with the zero address as its hook is a "vanilla pool" and behaves like a standard concentrated-liquidity AMM.

## The 10 core callback functions

Hooks anchor on 10 lifecycle callbacks, organized in before/after pairs around 5 pool actions:

| Action | Before callback | After callback |
|---|---|---|
| Pool initialization | `beforeInitialize` | `afterInitialize` |
| Add liquidity | `beforeAddLiquidity` | `afterAddLiquidity` |
| Remove liquidity | `beforeRemoveLiquidity` | `afterRemoveLiquidity` |
| Swap | `beforeSwap` | `afterSwap` |
| Donate | `beforeDonate` | `afterDonate` |

A hook does **not** need to implement all of these. It declares which subset it uses via `getHookPermissions()`.

## The 4 delta-returning flags

Beyond the 10 core callbacks, there are 4 additional permission flags that allow specific callbacks to return a `BalanceDelta` or `BeforeSwapDelta`, modifying the accounting:

- `beforeSwapReturnDelta` — `beforeSwap` can return a `BeforeSwapDelta` that alters the swap amounts
- `afterSwapReturnDelta` — `afterSwap` can return an `int128` delta in the unspecified currency
- `afterAddLiquidityReturnDelta` — `afterAddLiquidity` can return a `BalanceDelta` taken from / paid to the LP
- `afterRemoveLiquidityReturnDelta` — same for remove liquidity

This brings the total permission flags to **14**.

**Constraint**: a delta-returning flag requires its parent action flag. For example, `beforeSwapReturnDelta: true` requires `beforeSwap: true`. The `Hooks.sol` library validates this at deploy time.

## How permissions are encoded

The PoolManager determines which hooks to invoke by inspecting the **lowest 14 bits of the hook contract's address**. For example, a hook deployed to `0x0000000000000000000000000000000000002400` has lowest bits `10 0100 0000 0000`, which encodes `beforeInitialize: true` and `afterAddLiquidity: true`.

This means:
- Hook addresses **must be mined with CREATE2** to produce the correct flag bits.
- Permissions are **immutable** — they're encoded in the address itself, so you cannot change them post-deploy without redeploying to a new address.
- A mismatch between what `getHookPermissions()` returns and the address bits will cause `PoolManager.initialize` to revert.

The `HookMiner` utility in v4-periphery handles salt mining for you.

## Singleton architecture

All v4 pools live inside a single `PoolManager` contract — unlike v2/v3 where each pool was its own contract. Key consequences:
- Pool creation is a state update, not a contract deployment → much cheaper.
- Hooks are external calls **from** the PoolManager.
- The PoolManager uses **flash accounting** — token balances are tracked as transient deltas and must net to zero by the end of an `unlock` callback.
- Native ETH is supported directly (no WETH wrapping required).

## Common hook use cases

- Custom AMM curves (stable-swap, constant-sum, bonding curves)
- Dynamic fees based on volatility, time of day, or other signals
- On-chain limit orders
- TWAMM (time-weighted average market makers) for large orders
- LP incentive / points systems
- Yield optimization (routing idle liquidity to lending protocols)
- MEV protection (anti-sandwich, batch auctions)
- Compliance/KYC gating (RBAC hooks)
- Custom oracles

## Important caveat

Building a hook does **not** mean Uniswap's frontend will route liquidity to it. Hooks compete for liquidity and discoverability on their own merits.
