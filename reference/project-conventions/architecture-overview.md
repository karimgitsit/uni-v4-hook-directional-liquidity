# Uniswap v4 — Architecture Overview

> **Source**: https://docs.uniswap.org/contracts/v4/overview

## The three repositories

Uniswap v4 is split across three primary repos, each with a distinct role:

### 1. `Uniswap/v4-core` — the singleton PoolManager
Contains the protocol's essential logic. Home to **`PoolManager.sol`**, a singleton contract that:
- Acts as the **vault** for all assets across every v4 pool
- Holds all pool state (no per-pool contract deployments)
- Executes all swap, liquidity, and donate logic
- Calls hook contracts at the appropriate lifecycle points

The PoolManager is **not designed for direct end-user interaction**. Its interface is optimized for contract-to-contract calls via the `unlock` / `unlockCallback` pattern.

### 2. `Uniswap/v4-periphery` — user-facing helpers
Provides the abstraction layer between users and the core PoolManager:
- **`PositionManager.sol`** — ERC-721-backed liquidity position management
- **`V4Router.sol`** — swap routing
- **`V4Quoter.sol`** — quoting prices for swaps
- **`BaseHook.sol`** — the canonical base contract for writing hooks
- **`HookMiner.sol`** — utility for CREATE2 salt mining to produce valid hook addresses

### 3. `Uniswap/universal-router` — multi-protocol routing
Routes across v2, v3, v4, and other protocols. Less relevant for hook development but useful for understanding how external callers reach v4 pools.

## Key v4 innovations

| Innovation | What it does |
|---|---|
| **Hooks** | External contracts that customize pool behavior at lifecycle points |
| **Singleton PoolManager** | All pools share one contract → cheaper creation, cheaper multi-hop swaps |
| **Flash accounting** | Token balances tracked as transient deltas, settled at end of transaction |
| **Native ETH** | No more WETH wrapping for ETH pools |
| **Dynamic fees** | Fee per swap can be set by the hook via the `LPFeeLibrary` override flag |
| **Custom accounting** | Hooks with `*ReturnDelta` permissions can take/give value during operations |
| **ERC-6909 claim tokens** | Internal balances tracked as ERC-6909 instead of moving tokens around |

## The unlock / callback pattern

To execute any pool action (swap, modify liquidity, donate), an integrator calls `PoolManager.unlock(bytes calldata data)`. The PoolManager then calls back into the integrator's `unlockCallback` function, where the integrator can perform any number of actions on any number of pools.

The only invariant: by the end of `unlockCallback`, all currency deltas accumulated during the unlock must net to **zero**. This is "flash accounting."

Pool **initialization** is the exception — it can happen outside an `unlock` context.

```solidity
// Skeleton for an integrator contract
contract MyIntegrator is IUnlockCallback {
    IPoolManager poolManager;

    function doStuff() external {
        poolManager.unlock(abi.encode(/* my action data */));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Unauthorized");
        // perform pool actions: swap, modifyLiquidity, donate
        // ensure deltas net to zero before returning
    }
}
```

## Where hooks fit in

Hooks are **called by the PoolManager** during the lifecycle of pool actions. They are not called by users directly — though a malicious or poorly-designed hook can expose external functions that bypass this.

```
┌──────────┐  unlock  ┌─────────────┐  swap   ┌─────────┐
│  Router  │─────────▶│ PoolManager │────────▶│  Hook   │
└──────────┘          └─────────────┘  call    └─────────┘
                            │                       │
                            │     return delta      │
                            ◀───────────────────────┘
```

## Licensing note

Uniswap V4 Core is dual-licensed under the **Business Source License 1.1** (BUSL-1.1) and the **MIT License**. Until the BUSL change date, commercial production deployments are restricted. Check `BUSL_LICENSE` in the v4-core repo for current terms.
