# House Style: Uniswap v4 Hooks Development

This document defines the conventions, patterns, and defaults for hooks built in this project. When generating code, follow these unless the user explicitly overrides.

---

## 1. Project structure

```
my-hook-project/
├── src/
│   ├── HookName.sol              # The hook contract
│   └── interfaces/               # Any custom interfaces
├── script/
│   └── DeployHookName.s.sol      # CREATE2 deployment script
├── test/
│   ├── HookName.t.sol            # Main tests
│   └── utils/                    # Shared test helpers if needed
├── lib/                          # forge install dependencies
├── foundry.toml
└── remappings.txt
```

## 2. Required remappings

```
@uniswap/v4-core/=lib/v4-core/
v4-core/=lib/v4-core/
v4-periphery/=lib/v4-periphery/
permit2/=lib/v4-periphery/lib/permit2/
solmate/=lib/v4-core/lib/solmate/
forge-std/=lib/v4-core/lib/forge-std/src/
forge-gas-snapshot/=lib/v4-core/lib/forge-gas-snapshot/src/
@openzeppelin/=lib/openzeppelin-contracts/
```

## 3. Standard imports

Every hook starts with this import block (prune what's unused):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
```

## 4. Hook contract skeleton

```solidity
contract MyHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // Per-pool state — always key by PoolId, never use global state
    mapping(PoolId => uint256) public somethingPerPool;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,           // ← flip only what you actually use
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Implement only the underscore-prefixed internals for callbacks you opted into:
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // ... logic ...
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
```

## 5. Permission flag rules

- **Only enable flags you use.** Every enabled flag costs gas and increases attack surface.
- **`*ReturnDelta` flags require their parent flag.** `beforeSwapReturnDelta: true` requires `beforeSwap: true`. The `Hooks.sol` validation enforces this and reverts on deployment otherwise.
- **Permissions are immutable post-deploy** — they're encoded in the bottom 14 bits of the contract address.

## 6. CREATE2 deployment

Hook addresses encode permissions, so you must mine a salt. Use `HookMiner` from v4-periphery:

```solidity
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

uint160 flags = uint160(
    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
);

(address hookAddress, bytes32 salt) = HookMiner.find(
    CREATE2_DEPLOYER,        // 0x4e59b44847b379578588920cA78FbF26c0B4956C in forge script
    flags,
    type(MyHook).creationCode,
    abi.encode(address(poolManager))
);

MyHook hook = new MyHook{salt: salt}(IPoolManager(address(poolManager)));
require(address(hook) == hookAddress, "Hook address mismatch");
```

In `forge test` the deployer is `address(this)` (or the prank address). In `forge script` it's the CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

## 7. Security defaults — apply to every hook

### Access control
```solidity
// BaseHook already enforces this on the external IHooks functions, but if you
// add any other externally-callable function that touches hook state, add:
modifier onlyPoolManager() {
    require(msg.sender == address(poolManager), "Not pool manager");
    _;
}
```

### Reentrancy
- Any external call from inside a hook callback is a reentrancy risk.
- Use OpenZeppelin's `ReentrancyGuard` or v4's transient storage locks.
- Update state **before** external calls, never after.

### Pool validation
If your hook is meant for specific pools, validate the `PoolKey` on every callback:
```solidity
function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
    internal override returns (bytes4, BeforeSwapDelta, uint24) 
{
    require(_isAllowedPool(key), "Pool not allowed");
    // ...
}
```

### Custom accounting (delta-returning hooks)
- Be **paranoid** about sign and direction. Document every delta return value.
- Hooks with `*ReturnDelta` flags can drain liquidity if math is wrong.
- Always write fuzz tests for the accounting logic.

### Token assumptions
- Don't assume standard ERC-20 behavior. Fee-on-transfer, rebasing, and ERC-777-style tokens can break accounting.
- Don't assume `transfer` returns true — use `SafeERC20` or check return values.

## 8. Test conventions

Every hook gets a `<HookName>.t.sol` with at minimum:

```solidity
contract MyHookTest is Test, Deployers {
    MyHook hook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Mine the address with the right flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), flags, type(MyHook).creationCode, abi.encode(manager)
        );
        hook = new MyHook{salt: salt}(manager);
        require(address(hook) == hookAddr);

        // Initialize pool with hook
        (poolKey, poolId) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);
    }

    function test_permissions_matchExpectedFlags() public { /* ... */ }
    function test_callback_happyPath() public { /* ... */ }
    function test_callback_revertsOnUnauthorizedCaller() public { /* ... */ }
    function test_callback_handlesEdgeCase() public { /* ... */ }
    function testFuzz_accountingSoundness(uint128 amount) public { /* ... */ }
}
```

## 9. Common pitfalls (flag these in code review)

| Pitfall | Why it matters |
|---|---|
| Global state instead of per-`PoolId` mappings | One pool's state corrupts another |
| Missing `onlyPoolManager` on auxiliary functions | Anyone can spoof hook calls |
| Enabling `*ReturnDelta` flag without parent | Deployment reverts |
| Computing the wrong salt for permissions | Pool init reverts on flag mismatch |
| Calling external untrusted contracts mid-callback | Reentrancy |
| Assuming `amountSpecified > 0` means exact-output | It's the opposite — negative = exact-input |
| Reading pool state via `PoolManager` directly | Use `StateLibrary` getters instead |
| Forgetting to return the function selector | Hook calls revert with `InvalidHookResponse` |

## 10. When in doubt

- Check `BaseHook.sol` for the canonical override signatures.
- Check `Hooks.sol` (the library) for the flag constants and validation logic.
- Check `v4-periphery` reference hooks for working patterns.
- Default to the simplest correct implementation; optimize only with measurements.
