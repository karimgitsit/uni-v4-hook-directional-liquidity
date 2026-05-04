# `PointsHook.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// PointsHook from the official Uniswap "Building Your First Hook" tutorial:
// https://docs.uniswap.org/contracts/v4/guides/hooks/your-first-hook
//
// This hook awards "points" (an ERC-20 the hook mints) to users who swap ETH
// into a target token, and to LPs who add liquidity. It's a good reference for:
//   - Reading the swap delta to determine how much ETH was spent
//   - Decoding hookData to identify the user being rewarded
//   - Handling currency0 == native ETH (address(0))
//   - The afterSwap + afterAddLiquidity pattern for incentive distribution

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract PointsHook is BaseHook {
    // Points balance per user. In the real tutorial this is a separate ERC-20 token.
    mapping(address => uint256) public points;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Only award points in ETH/TOKEN pools (currency0 must be native ETH)
        if (!key.currency0.isAddressZero()) {
            return (BaseHook.afterSwap.selector, 0);
        }
        // Only award points if the user is buying TOKEN (zeroForOne = swapping ETH in)
        if (!swapParams.zeroForOne) {
            return (BaseHook.afterSwap.selector, 0);
        }

        address user = _parseHookData(hookData);
        if (user == address(0)) return (BaseHook.afterSwap.selector, 0);

        // delta.amount0() is negative when user spent ETH (exact-input swap)
        // Negating gives the absolute amount spent.
        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));
        points[user] += ethSpendAmount;

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (!key.currency0.isAddressZero()) {
            return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        address user = _parseHookData(hookData);
        if (user == address(0)) return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));

        // Award points equal to ETH supplied as liquidity
        uint256 ethAdded = uint256(int256(-delta.amount0()));
        points[user] += ethAdded;

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _parseHookData(bytes calldata hookData) internal pure returns (address user) {
        if (hookData.length < 32) return address(0);
        user = abi.decode(hookData, (address));
    }
}
```
