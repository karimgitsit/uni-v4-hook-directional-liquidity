// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {DirectionalLiquidityHook} from "../src/DirectionalLiquidityHook.sol";

/// @title DeployDirectionalLiquidityHook
/// @notice Mines a CREATE2 salt that lands the hook at an address whose low
///         14 bits encode `beforeAddLiquidity | beforeRemoveLiquidity |
///         afterSwap`, then deploys via the canonical CREATE2 deployer
///         proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`).
///
///         Usage:
///           forge script script/DeployDirectionalLiquidityHook.s.sol \
///             --rpc-url <RPC> --broadcast \
///             --sig 'run(address,address,address,uint24,int24,uint24,uint32,uint16,uint16,string,string)' \
///             $POOL_MANAGER $TOKEN0 $TOKEN1 $FEE $TICK_SPACING \
///             $BIN_WIDTH $TWAP_WINDOW $KEEPER_BPS $BUFFER $NAME $SYMBOL
///
///         All non-PoolManager parameters become hook immutables.
contract DeployDirectionalLiquidityHook is Script {
    /// @notice Thrown when `_mineForFlags` fails to find a self-consistent
    ///         (mined-address, embedded-PoolKey-hooks) fixed point inside
    ///         `MINE_MAX_ITERATIONS` passes. Surfaces a clear deploy-time
    ///         failure rather than letting a stale-args salt slip through
    ///         to the constructor (where it would revert with the less
    ///         specific `"PoolKey hook != this"`).
    error MiningDidNotConverge();

    /// @dev Foundry's standard CREATE2 deployer proxy address. `forge
    ///      script --broadcast` deploys CREATE2 contracts through this
    ///      proxy, so the salt must be mined against this `deployer`.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Maximum iterations of the salt-mining fixed-point loop. The
    ///      loop usually converges in 1–2 passes; allow some headroom in
    ///      case a future HookMiner change makes the search space less
    ///      stable. Reverts with `MiningDidNotConverge` if exceeded.
    uint256 constant MINE_MAX_ITERATIONS = 8;

    /// @dev Bundles all deployment parameters so the mining helper
    ///      doesn't hit Solidity's stack budget.
    /// @param poolManager      Address of the v4 PoolManager.
    /// @param token0           Lower-sorted ERC20 (or zero for native).
    /// @param token1           Higher-sorted ERC20.
    /// @param fee              Pool LP fee, hundredths of a bip.
    /// @param tickSpacing      Pool tick spacing.
    /// @param binWidth         Hook bin width (multiples of tickSpacing).
    /// @param twapWindow       TWAP window in seconds.
    /// @param keeperRewardBps  Keeper share of rebalance fees, in bps.
    /// @param bufferSize       TWAP ring-buffer capacity.
    /// @param name             ERC-721 collection name.
    /// @param symbol           ERC-721 collection symbol.
    struct DeployParams {
        address poolManager;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        uint24 binWidth;
        uint32 twapWindow;
        uint16 keeperRewardBps;
        uint16 bufferSize;
        string name;
        string symbol;
    }

    /// @notice Compute the flag mask this hook needs encoded in its address.
    /// @return mask Bitwise OR of the v4 hook permission flags this hook
    ///         enables — the low 14 bits the mined address must match.
    function expectedFlags() public pure returns (uint160 mask) {
        return uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    }

    /// @notice Convenience entry point that takes raw addresses (so the
    ///         script is callable from a CLI without needing to construct
    ///         a `PoolKey` struct).
    /// @dev    `token0` and `token1` must already be sorted (token0 < token1).
    /// @param poolManager      v4 PoolManager address.
    /// @param token0           Lower-sorted token (or zero for native ETH).
    /// @param token1           Higher-sorted token.
    /// @param fee              Pool LP fee, hundredths of a bip.
    /// @param tickSpacing      Pool tick spacing.
    /// @param binWidth         Hook bin width (multiples of tickSpacing).
    /// @param twapWindow       TWAP window in seconds.
    /// @param keeperRewardBps  Keeper share of rebalance fees, in bps.
    /// @param bufferSize       TWAP ring-buffer capacity.
    /// @param name             ERC-721 collection name.
    /// @param symbol           ERC-721 collection symbol.
    /// @return hook            Newly-deployed hook contract.
    function run(
        address poolManager,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        uint24 binWidth,
        uint32 twapWindow,
        uint16 keeperRewardBps,
        uint16 bufferSize,
        string memory name,
        string memory symbol
    ) external returns (DirectionalLiquidityHook hook) {
        require(token0 < token1, "tokens not sorted");
        DeployParams memory p = DeployParams({
            poolManager: poolManager,
            token0: token0,
            token1: token1,
            fee: fee,
            tickSpacing: tickSpacing,
            binWidth: binWidth,
            twapWindow: twapWindow,
            keeperRewardBps: keeperRewardBps,
            bufferSize: bufferSize,
            name: name,
            symbol: symbol
        });
        return runWithParams(p);
    }

    /// @notice Same as `run` but takes a struct — convenient for callers
    ///         that already build their params programmatically.
    /// @param p    Bundled deployment parameters.
    /// @return hook Newly-deployed hook contract.
    function runWithParams(DeployParams memory p) public returns (DirectionalLiquidityHook hook) {
        bytes memory creationCode = type(DirectionalLiquidityHook).creationCode;
        (address hookAddr, bytes32 salt) = _mineForFlags(creationCode, p);

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(p.token0),
            currency1: Currency.wrap(p.token1),
            fee: p.fee,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast();
        hook = new DirectionalLiquidityHook{salt: salt}(
            IPoolManager(p.poolManager), pk, p.binWidth, p.twapWindow, p.keeperRewardBps, p.bufferSize, p.name, p.symbol
        );
        vm.stopBroadcast();

        require(address(hook) == hookAddr, "deployed address mismatch");
        console2.log("DirectionalLiquidityHook deployed at:", address(hook));
        console2.log("Salt:", uint256(salt));
        _logBufferSizeHeuristic(p.bufferSize, p.twapWindow);
        return hook;
    }

    /// @dev Emit a coverage table comparing the chosen `bufferSize` against
    ///      the `twapWindow`, assuming one TWAP observation per block at a
    ///      few common L1/L2 block times. The hook needs at least one
    ///      observation older than `twapWindow` to compute a real average;
    ///      a buffer that can't span the window at the target chain's block
    ///      time degrades TWAP into "last tick" until enough swaps land.
    /// @param bufferSize The configured TWAP ring-buffer capacity.
    /// @param twapWindow The configured TWAP averaging window, in seconds.
    function logBufferSizeHeuristic(uint16 bufferSize, uint32 twapWindow) public pure {
        _logBufferSizeHeuristic(bufferSize, twapWindow);
    }

    function _logBufferSizeHeuristic(uint16 bufferSize, uint32 twapWindow) internal pure {
        console2.log("--- TWAP coverage (assumes one observation per block) ---");
        console2.log("twapWindow (s):", uint256(twapWindow));
        console2.log("bufferSize:    ", uint256(bufferSize));
        // (block time s, label) pairs — kept inline to avoid a struct array.
        _logChainCoverage("Ethereum L1 (12s blocks)", bufferSize, twapWindow, 12);
        _logChainCoverage("Polygon/Base/OP (2s blocks)", bufferSize, twapWindow, 2);
        _logChainCoverage("Arbitrum (0.25s blocks)   ", bufferSize, twapWindow, 1); // uses 1s as the floor
    }

    /// @dev Per-chain coverage line for `_logBufferSizeHeuristic`. Also
    ///      flags when the buffer can't span the window.
    /// @param label       Human-readable chain label.
    /// @param bufferSize  Hook's `bufferSize` immutable.
    /// @param twapWindow  Hook's `twapWindow` immutable.
    /// @param blockTimeS  Heuristic block time, in seconds.
    function _logChainCoverage(string memory label, uint16 bufferSize, uint32 twapWindow, uint32 blockTimeS)
        internal
        pure
    {
        uint256 coverage = uint256(bufferSize) * uint256(blockTimeS);
        if (coverage < uint256(twapWindow)) {
            console2.log(string.concat("  WARN ", label, ": coverage(s)="), coverage);
        } else {
            console2.log(string.concat("  OK   ", label, ": coverage(s)="), coverage);
        }
    }

    /// @dev Iteratively mines a salt. The hook constructor requires
    ///      `poolKey.hooks == address(this)`, but the hook address itself
    ///      depends on the salt, which depends on the constructor args
    ///      (which include the PoolKey). We resolve the fixed point by
    ///      iterating: mine with `hooks=candidate`, set `candidate` to the
    ///      mined address, repeat. Convergence (mined == candidate) means
    ///      the constructor args contain the address the deployment will
    ///      actually land at, so the constructor's `hooks == this` check
    ///      will pass. If the loop fails to converge inside
    ///      `MINE_MAX_ITERATIONS`, revert with `MiningDidNotConverge`
    ///      rather than returning stale (mined-address, salt) where the
    ///      salt was computed from a different `args` than the one we'd
    ///      deploy with.
    /// @param creationCode Hook contract's creation bytecode.
    /// @param p            Deployment parameters used to encode the args.
    /// @return hookAddr    The mined CREATE2 address.
    /// @return salt        The salt that produces `hookAddr`.
    function _mineForFlags(bytes memory creationCode, DeployParams memory p)
        internal
        view
        returns (address hookAddr, bytes32 salt)
    {
        address candidateHooks = address(0);
        for (uint256 i = 0; i < MINE_MAX_ITERATIONS; i++) {
            PoolKey memory pkProbe = PoolKey({
                currency0: Currency.wrap(p.token0),
                currency1: Currency.wrap(p.token1),
                fee: p.fee,
                tickSpacing: p.tickSpacing,
                hooks: IHooks(candidateHooks)
            });
            bytes memory args = abi.encode(
                IPoolManager(p.poolManager),
                pkProbe,
                p.binWidth,
                p.twapWindow,
                p.keeperRewardBps,
                p.bufferSize,
                p.name,
                p.symbol
            );
            (hookAddr, salt) = HookMiner.find(CREATE2_DEPLOYER, expectedFlags(), creationCode, args);
            if (hookAddr == candidateHooks) return (hookAddr, salt);
            candidateHooks = hookAddr;
        }
        revert MiningDidNotConverge();
    }
}
