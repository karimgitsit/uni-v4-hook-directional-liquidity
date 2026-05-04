# Setting Up a v4 Hook Development Environment

> **Sources**:
> - https://docs.uniswap.org/contracts/v4/quickstart/hooks/setup
> - https://docs.uniswap.org/contracts/v4/guides/hooks/your-first-hook
> - https://github.com/uniswapfoundation/v4-template

## Quick start: use the v4-template

The fastest way to start is the official template, which has all dependencies and test fixtures pre-wired:

```bash
git clone https://github.com/uniswapfoundation/v4-template.git
cd v4-template
forge install
forge test
```

The template includes `Counter.sol` (a basic hook demonstrating beforeSwap/afterSwap) and `Counter.t.sol` with a preconfigured PoolManager, test tokens, and test liquidity.

## Manual setup from scratch

If you'd rather build the project yourself:

```bash
# 1. Initialize a Foundry project
forge init my-hook
cd my-hook

# 2. Install Uniswap dependencies
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery

# 3. Optionally install OpenZeppelin's audited hooks library
forge install OpenZeppelin/uniswap-hooks
```

### `remappings.txt`

```
@uniswap/v4-core/=lib/v4-core/
v4-core/=lib/v4-core/
v4-periphery/=lib/v4-periphery/
permit2/=lib/v4-periphery/lib/permit2/
solmate/=lib/v4-core/lib/solmate/
forge-std/=lib/v4-core/lib/forge-std/src/
forge-gas-snapshot/=lib/v4-core/lib/forge-gas-snapshot/src/
@openzeppelin/uniswap-hooks/=lib/uniswap-hooks/src/
```

### Foundry version

The v4-template is designed to work with **Foundry stable**. Foundry Nightly has caused compatibility issues. Update with `foundryup` if you hit weird errors.

## Running a local node

Hooks exceed the standard Ethereum bytecode limit and v4-core is BUSL-licensed, so for development you'll typically work against a local Anvil node:

```bash
# Terminal 1: start anvil with a larger code size limit
anvil --code-size-limit 30000

# Terminal 2: deploy
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key <test_key> \
  --code-size-limit 30000 \
  --broadcast

# Terminal 2: test against local node
forge test --rpc-url 127.0.0.1:8545
```

## CREATE2 deployment quirk

Because hook permissions are encoded in the contract address, you must use CREATE2 to deploy hooks at a specific address. The salt that produces the right address is found via `HookMiner.find(...)`.

**Important**: the deployer differs by context.
- In `forge test`: the deployer is `address(this)` (or the active prank address). Both `new Hook{salt}` and `HookMiner.find(deployer, ...)` use this.
- In `forge script` with `--broadcast`: the deployer is the canonical CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`. If your local Anvil doesn't have this proxy pre-deployed, run `foundryup` to update.

## A minimal hook (Counter pattern)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract MyHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => uint256) public swapCount;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,        // ← only enable what you use
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        swapCount[key.toId()]++;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
```

## Reading the swap delta

When implementing `_afterSwap`, the `BalanceDelta delta` parameter encodes how much currency moved:
- `delta.amount0()` and `delta.amount1()` are `int128` values.
- **Negative** = the user paid that amount of that currency (currency left the user).
- **Positive** = the user received that amount of that currency.
- For `zeroForOne` (selling currency0): `amount0()` will be negative, `amount1()` positive.

So if you want to know how much currency0 the user spent on an exact-input swap:
```solidity
uint256 spent = uint256(int256(-delta.amount0()));
```

## Standard test fixtures

The v4-template (and `Deployers` from v4-core's test utilities) provide helpers:
- `deployFreshManagerAndRouters()` — sets up a PoolManager and test routers
- `deployMintAndApprove2Currencies()` — deploys two test ERC-20s and approves them
- `initPool(currency0, currency1, hook, fee, sqrtPrice)` — initializes a hooked pool

These should be your starting point when writing tests.
