// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, StdInvariant} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DirectionalLiquidityHook} from "../src/DirectionalLiquidityHook.sol";
import {ModeRange} from "../src/libraries/ModeRange.sol";
import {ShareMath} from "../src/libraries/ShareMath.sol";

/// @title DirectionalLiquidityHookInvariants
/// @notice Stateful invariant fuzz over the hook's external surface. The
///         handler picks random sequences of deposit/withdraw/rebalance/
///         swap calls; after each call, every invariant below must still
///         hold for the hook to be sound.
/// @dev    Uses an ERC20-only fixture (no native ETH) so fee accounting is
///         visible directly in `token{0,1}.balanceOf(hook)`. The handler's
///         shadow-tracked `liveTokenIds` array stands in for ERC721
///         enumeration (the hook itself is non-enumerable).
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract DirectionalLiquidityHookInvariants is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant EXPECTED_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;
    uint24 internal constant FEE = 10_000; // 1% — keep fees visible
    uint24 internal constant BIN_WIDTH = 1;
    uint32 internal constant TWAP_WINDOW = 600;
    uint16 internal constant KEEPER_REWARD_BPS = 500;
    uint16 internal constant BUFFER_SIZE = 64;

    PoolManager internal manager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    DirectionalLiquidityHook internal hook;
    PoolSwapTest internal swapRouter;
    DLHHandler internal handler;

    function setUp() public {
        manager = new PoolManager(address(this));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Distinct prefix so we don't alias any other test's hook addr.
        address hookAddr = address(uint160(0xAAAA << 144) | uint160(EXPECTED_FLAGS));
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        deployCodeTo(
            "DirectionalLiquidityHook.sol:DirectionalLiquidityHook",
            abi.encode(
                IPoolManager(address(manager)),
                key,
                BIN_WIDTH,
                TWAP_WINDOW,
                KEEPER_REWARD_BPS,
                BUFFER_SIZE,
                "DLP",
                "DLP"
            ),
            hookAddr
        );
        hook = DirectionalLiquidityHook(payable(hookAddr));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        handler = new DLHHandler(hook, manager, key, token0, token1, swapRouter);

        // Restrict the invariant runner to the handler's deliberate
        // entrypoints — without this the runner would also pick random
        // selectors from inherited Test machinery.
        bytes4[] memory sels = new bytes4[](4);
        sels[0] = DLHHandler.deposit.selector;
        sels[1] = DLHHandler.withdrawAt.selector;
        sels[2] = DLHHandler.rebalanceAttempt.selector;
        sels[3] = DLHHandler.swap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- //
    // Invariants                                                       //
    // ---------------------------------------------------------------- //

    /// @notice For each mode, sum of LP shares across live NFTs equals
    ///         `_modes[mode].totalShares`. Spec §6 storage layout.
    function invariant_sharesSumToTotal() public view {
        uint256[3] memory sums;
        uint256[] memory ids = handler.liveTokenIdsAll();
        for (uint256 i = 0; i < ids.length; i++) {
            DirectionalLiquidityHook.PositionInfo memory pos = hook.positionInfo(ids[i]);
            sums[pos.mode] += uint256(pos.shares);
        }
        for (uint8 m = 0; m < 3; m++) {
            DirectionalLiquidityHook.ModeState memory ms = hook.modeState(m);
            assertEq(uint256(ms.totalShares), sums[m], "share sum != totalShares");
        }
    }

    /// @notice `initialized` is exactly equivalent to "mode has live LPs".
    ///         Last-LP cleanup (spec §5.3.9) keeps this tight.
    function invariant_initializedIffNonempty() public view {
        for (uint8 m = 0; m < 3; m++) {
            DirectionalLiquidityHook.ModeState memory ms = hook.modeState(m);
            assertEq(ms.initialized, ms.totalShares > 0, "initialized != (totalShares > 0)");
        }
    }

    /// @notice Hook's ERC20 balance covers the sum of unclaimed fees owed
    ///         to all current LPs across all modes. This is the property
    ///         that makes the accumulator pattern self-funding: the hook
    ///         holds others' fees as ERC20 balance until they withdraw.
    /// @dev    Note: `>=`, not `==`. A withdraw that burns the last share
    ///         of a mode triggers `delete _modes[mode]`, which zeroes the
    ///         accumulator — but the v4 burn returns the FULL fee delta in
    ///         that step, and the withdrawing LP only takes their pro-rata
    ///         slice. Any rounding dust stays as residual hook balance.
    ///         Same dust appears on partial-withdraw rounding.
    function invariant_hookBalanceCoversUnclaimedFees() public view {
        uint256 owed0;
        uint256 owed1;
        uint256[] memory ids = handler.liveTokenIdsAll();
        for (uint256 i = 0; i < ids.length; i++) {
            DirectionalLiquidityHook.PositionInfo memory pos = hook.positionInfo(ids[i]);
            DirectionalLiquidityHook.ModeState memory ms = hook.modeState(pos.mode);
            owed0 += ShareMath.pendingFees(pos.shares, ms.feePerShareCumulative0, pos.feeSnapshot0);
            owed1 += ShareMath.pendingFees(pos.shares, ms.feePerShareCumulative1, pos.feeSnapshot1);
        }
        assertGe(token0.balanceOf(address(hook)), owed0, "hook bal0 < owed0");
        assertGe(token1.balanceOf(address(hook)), owed1, "hook bal1 < owed1");
    }

    /// @notice Every NFT id the handler thinks is live must (a) still
    ///         exist on the hook and (b) carry a non-zero share count.
    ///         Conversely, burned ids must be absent — encoded by removing
    ///         them from `liveTokenIds` in the handler's withdraw path.
    function invariant_nftPositionParity() public view {
        uint256[] memory ids = handler.liveTokenIdsAll();
        for (uint256 i = 0; i < ids.length; i++) {
            address owner = hook.ownerOf(ids[i]); // reverts if burned
            assertEq(owner, address(handler), "live NFT not owned by handler");
            DirectionalLiquidityHook.PositionInfo memory pos = hook.positionInfo(ids[i]);
            assertGt(uint256(pos.shares), 0, "live NFT has zero-share position");
        }
    }
}

/// @notice Stateful handler driving the invariant fuzz. Owns its own
///         token balances, holds every LP NFT it mints, and shadow-tracks
///         live token ids so the invariant runner has something to iterate.
/// @dev    Inherits `Test` for `bound` + vm cheats (we use `vm.prank` to
///         seed observations from msg.sender = manager when the natural
///         swap path doesn't fire one).
contract DLHHandler is Test {
    using StateLibrary for IPoolManager;

    DirectionalLiquidityHook internal hook;
    PoolManager internal manager;
    PoolKey internal key;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolSwapTest internal swapRouter;

    uint256[] internal _live;
    mapping(uint256 => uint256) internal _liveIdxPlusOne; // 1-based; 0 = absent

    // Bookkeeping for debugging / call-summary output. Not load-bearing
    // for invariants — useful when a run fails so we can see what was
    // actually exercised.
    uint256 public depositCalls;
    uint256 public depositOk;
    uint256 public withdrawCalls;
    uint256 public withdrawOk;
    uint256 public rebalanceCalls;
    uint256 public rebalanceOk;
    uint256 public swapCalls;
    uint256 public swapOk;

    constructor(
        DirectionalLiquidityHook _hook,
        PoolManager _manager,
        PoolKey memory _key,
        MockERC20 _token0,
        MockERC20 _token1,
        PoolSwapTest _swapRouter
    ) {
        hook = _hook;
        manager = _manager;
        key = _key;
        token0 = _token0;
        token1 = _token1;
        swapRouter = _swapRouter;

        // Pre-fund the handler. The values are oversized so the fuzz can
        // run depth=64 without exhausting balance under any plausible
        // trajectory.
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    /// @notice Read-only view of the live tokenId set. The invariant test
    ///         iterates this in lieu of ERC721 enumeration (the hook is
    ///         non-enumerable).
    function liveTokenIdsAll() external view returns (uint256[] memory) {
        return _live;
    }

    function liveCount() external view returns (uint256) {
        return _live.length;
    }

    // ---------------------------------------------------------------- //
    // Action: deposit                                                  //
    // ---------------------------------------------------------------- //

    /// @notice Random deposit. `mode` is bounded into [0, 3); `liqRaw` is
    ///         bounded into a "useful" liquidity range — too small and v4
    ///         rounds the share count to zero, too large and we'd risk
    ///         overflowing v4's per-tick accumulators.
    function deposit(uint8 modeRaw, uint96 liqRaw) external {
        depositCalls++;
        uint8 mode = uint8(_bound(uint256(modeRaw), 0, 2));
        uint128 liq = uint128(_bound(uint256(liqRaw), 1e15, 1e21));
        try hook.deposit(mode, liq, address(this)) returns (uint256 tokenId) {
            _live.push(tokenId);
            _liveIdxPlusOne[tokenId] = _live.length;
            depositOk++;
        } catch {}
    }

    // ---------------------------------------------------------------- //
    // Action: withdraw (by index into live set)                        //
    // ---------------------------------------------------------------- //

    function withdrawAt(uint256 idxRaw) external {
        withdrawCalls++;
        uint256 n = _live.length;
        if (n == 0) return;
        uint256 idx = _bound(idxRaw, 0, n - 1);
        uint256 tokenId = _live[idx];
        try hook.withdraw(tokenId, address(this)) {
            // Swap-and-pop. Maintain `_liveIdxPlusOne` in lockstep so a
            // failed assertion can pinpoint state.
            uint256 lastIdx = _live.length - 1;
            if (idx != lastIdx) {
                uint256 last = _live[lastIdx];
                _live[idx] = last;
                _liveIdxPlusOne[last] = idx + 1;
            }
            _live.pop();
            _liveIdxPlusOne[tokenId] = 0;
            withdrawOk++;
        } catch {}
    }

    // ---------------------------------------------------------------- //
    // Action: rebalance attempt                                        //
    // ---------------------------------------------------------------- //

    /// @notice Try to rebalance. Most calls revert (`NothingToRebalance`)
    ///         when no mode's TWAP trigger fires; that's expected. The
    ///         carry-forward CLAUDE.md note about the same-bin shortcut
    ///         means rebalance can also commit a Mode-Both dir flip
    ///         WITHOUT unlocking — invariants must still hold.
    function rebalanceAttempt() external {
        rebalanceCalls++;
        try hook.rebalance() {
            rebalanceOk++;
        } catch {}
    }

    // ---------------------------------------------------------------- //
    // Action: swap (drives fees, moves price, writes observations)     //
    // ---------------------------------------------------------------- //

    /// @notice Random real swap. Bounds the price-limit tick into a window
    ///         where we know first-deposit positions plausibly land
    ///         (±300 ticks, with binTicks=60), and the spend amount into
    ///         a range that won't bankrupt the handler over a depth=64
    ///         run.
    function swap(int24 limitTickRaw, uint96 amtRaw) external {
        swapCalls++;
        // Slot0 might be empty if the pool never had a swap. Initialize
        // happened in setUp(), so spot tick is well-defined. Read it.
        (, int24 spot,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        int24 limitTick = int24(_bound(int256(limitTickRaw), -300, 300));
        if (limitTick == spot) limitTick = spot + 60; // force movement
        bool zeroForOne = limitTick < spot;
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        uint256 amt = _bound(uint256(amtRaw), 1e10, 1e18);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amt),
            sqrtPriceLimitX96: limit
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // Advance time so each swap's TWAP observation has a fresh
        // timestamp — without this they'd all collapse onto the same
        // second and the buffer would never span the window.
        vm.warp(block.timestamp + 30);
        try swapRouter.swap(key, params, settings, bytes("")) {
            swapOk++;
        } catch {}
    }
}
