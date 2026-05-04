// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

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

/// @title DirectionalLiquidityHookFeeTest
/// @notice Swap-driven end-to-end tests for fee accrual, JIT defense,
///         keeper reward split, and fee conservation. Uses a 1% LP fee
///         pool so fee numbers stay in round-ish ranges and assertion
///         tolerances can stay tight.
/// @dev    Lives in a separate contract from the main hook test so the
///         pool's fee can be set without disturbing existing tests.
contract DirectionalLiquidityHookFeeTest is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant EXPECTED_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;

    // 1% LP fee — round number for fee math.
    uint24 internal constant FEE = 10_000;
    uint24 internal constant BIN_WIDTH = 1;
    uint32 internal constant TWAP_WINDOW = 600;
    uint16 internal constant KEEPER_REWARD_BPS = 500; // 5%
    uint16 internal constant BUFFER_SIZE = 64;
    string internal constant NAME = "Directional Liquidity Position";
    string internal constant SYMBOL = "DLP";

    PoolManager internal manager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    DirectionalLiquidityHook internal hook;
    PoolSwapTest internal swapRouter;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal swapper = makeAddr("swapper");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        manager = new PoolManager(address(this));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Different prefix from the main test contract so the two address
        // spaces never alias even when run in the same forge invocation.
        address hookAddr = address(uint160(0x5555 << 144) | uint160(EXPECTED_FLAGS));

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
                IPoolManager(address(manager)), key, BIN_WIDTH, TWAP_WINDOW, KEEPER_REWARD_BPS, BUFFER_SIZE, NAME, SYMBOL
            ),
            hookAddr
        );
        hook = DirectionalLiquidityHook(payable(hookAddr));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        _fund(alice);
        _fund(bob);
        _fund(swapper);
    }

    function _fund(address who) internal {
        token0.mint(who, 1_000_000 ether);
        token1.mint(who, 1_000_000 ether);
        vm.startPrank(who);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Real swap via PoolSwapTest. Direction inferred from where
    ///      `targetTick` sits relative to the current spot tick. Stops at
    ///      `targetTick`'s sqrt-price OR at `amountIn` exhausted, whichever
    ///      comes first.
    function _realSwap(int24 targetTick, uint256 amountIn) internal {
        (, int24 spotTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        bool zeroForOne = targetTick < spotTick;
        uint160 limit = TickMath.getSqrtPriceAtTick(targetTick);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: limit
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(swapper);
        swapRouter.swap(key, params, settings, bytes(""));
    }

    /// @dev Drive price down through `[-60, 0)`, then back up to ~tick 0.
    ///      Each leg accrues fees in a position covering that range. Used
    ///      to generate predictable fees for accumulator-and-payout tests.
    ///      Caller controls warps before/after — observations are written
    ///      at the post-swap timestamp.
    function _swapDownAndBack(uint256 amountIn) internal {
        _realSwap(-120, amountIn);
        _realSwap(0, amountIn);
    }

    /// @dev Like `_callAfterSwap` from the main test file. Used to pile
    ///      observations for TWAP convergence without doing real swaps.
    function _seedTwapAt(int24 tick, uint16 steps, uint32 intervalSec) internal {
        for (uint16 i = 0; i < steps; i++) {
            vm.warp(block.timestamp + intervalSec);
            _setPoolPriceAtTick(tick);
            vm.prank(address(manager));
            hook.afterSwap(
                address(this),
                key,
                SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}),
                BalanceDelta.wrap(0),
                bytes("")
            );
        }
    }

    /// @dev Coherent slot0 write (sqrtPrice + tick), used by `_seedTwapAt`
    ///      so subsequent swap-limit checks still see a valid price.
    function _setPoolPriceAtTick(int24 t) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        uint160 sqrt = TickMath.getSqrtPriceAtTick(t);
        uint256 packed = uint256(sqrt);
        packed |= uint256(uint24(t)) << 160;
        vm.store(address(manager), stateSlot, bytes32(packed));
    }

    // ---------------------------------------------------------------- //
    // Fee tests                                                        //
    // ---------------------------------------------------------------- //

    function test_fees_jitAttackerGetsNothing() public {
        // Alice is the legit LP; Bob is the JIT attacker who deposits AFTER
        // fees have accrued, then withdraws immediately. The accumulator
        // pattern should fold all pre-deposit fees to Alice and snapshot
        // Bob's entry at the post-poke value, leaving him with 0 fees.
        vm.warp(1_000);

        uint256 aliceT0Before = token0.balanceOf(alice);
        uint256 aliceT1Before = token1.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceId = hook.deposit(ModeRange.MODE_RIGHT, 100e18, alice);

        // Generate fees: round-trip swap that crosses Alice's position.
        // (The accumulator stays 0 until something pokes the v4 position;
        // Bob's deposit will trigger that poke and pull pending fees in.)
        _swapDownAndBack(2e18);

        // Bob's JIT deposit. The poke inside _doDeposit must accrue all
        // pre-fees into the accumulator BEFORE issuing his shares so his
        // snapshot equals the current accumulator.
        uint256 bobT0Before = token0.balanceOf(bob);
        uint256 bobT1Before = token1.balanceOf(bob);
        vm.prank(bob);
        uint256 bobId = hook.deposit(ModeRange.MODE_RIGHT, 100e18, bob);
        DirectionalLiquidityHook.PositionInfo memory bobPos = hook.positionInfo(bobId);
        DirectionalLiquidityHook.ModeState memory postBob = hook.modeState(ModeRange.MODE_RIGHT);

        // The poke must have folded the pre-Bob fees into the accumulator
        // (so they're attributed to Alice's pre-existing shares, not split
        // with Bob).
        assertGt(postBob.feePerShareCumulative0, 0, "poke folded t0 fees in");
        assertGt(postBob.feePerShareCumulative1, 0, "poke folded t1 fees in");
        // Bob's snapshot equals the current accumulator → pendingFees(bob)
        // starts at exactly 0 and only grows from post-Bob fees.
        assertEq(bobPos.feeSnapshot0, postBob.feePerShareCumulative0, "bob's snap = post-poke accum (t0)");
        assertEq(bobPos.feeSnapshot1, postBob.feePerShareCumulative1, "bob's snap = post-poke accum (t1)");

        // Bob withdraws immediately — nothing happened between deposit and
        // withdraw, so pendingFees(bob) must be exactly 0.
        vm.prank(bob);
        hook.withdraw(bobId, bob);

        int256 bobNetT0 = int256(token0.balanceOf(bob)) - int256(bobT0Before);
        int256 bobNetT1 = int256(token1.balanceOf(bob)) - int256(bobT1Before);
        // Tiny rounding from v4's modifyLiquidity allowed; well below the
        // expected fee magnitude (≈ amountIn * 1% ≈ 2e16).
        assertApproxEqAbs(bobNetT0, int256(0), 1e10, "bob earned no t0 fees");
        assertApproxEqAbs(bobNetT1, int256(0), 1e10, "bob earned no t1 fees");

        // Alice withdraws and collects all the fees she earned.
        vm.prank(alice);
        hook.withdraw(aliceId, alice);
        int256 aliceNetT0 = int256(token0.balanceOf(alice)) - int256(aliceT0Before);
        int256 aliceNetT1 = int256(token1.balanceOf(alice)) - int256(aliceT1Before);
        // Alice should have earned fees in BOTH currencies (one per swap
        // leg). The exact magnitudes depend on the price path; we only
        // require strictly positive, well above bob-style rounding noise.
        assertGt(aliceNetT0, int256(1e14), "alice earned t0 fees");
        assertGt(aliceNetT1, int256(1e14), "alice earned t1 fees");
    }

    function test_fees_keeperGetsConfiguredCutOnRebalance() public {
        // Setup: one LP, fees accrue from a round-trip swap, then we
        // drive TWAP past the Mode-Right trigger. Calling rebalance from
        // a keeper address must split the on-burn fees according to
        // KEEPER_REWARD_BPS, with the LP cut folded into the accumulator.
        vm.warp(1_000);

        vm.prank(alice);
        hook.deposit(ModeRange.MODE_RIGHT, 100e18, alice);

        // Accrue fees in [-60, 0) via real swaps. (Fees sit in v4's per-
        // position accounting until a poke / withdraw / rebalance pulls
        // them into our accumulator — so accumulator stays 0 here.)
        _swapDownAndBack(2e18);

        // Snapshot accumulator before rebalance. Should be 0 since no
        // poke has happened yet.
        DirectionalLiquidityHook.ModeState memory preReb = hook.modeState(ModeRange.MODE_RIGHT);
        assertEq(preReb.feePerShareCumulative0, 0, "accum still 0 pre-rebalance");

        // Drive TWAP past the trigger by faking observations at tick 200.
        // (Real swaps that direction would just glide above the position
        // with no fee impact, so this is equivalent for trigger purposes.)
        _seedTwapAt(200, 12, 60);

        uint256 keeperT0Before = token0.balanceOf(keeper);
        uint256 keeperT1Before = token1.balanceOf(keeper);

        vm.prank(keeper);
        hook.rebalance();

        // Pull-pattern reward: rebalance credits the keeper's escrow;
        // the keeper later claims with `claimKeeperReward`. Snapshot the
        // owed amounts mid-flight so the bps assertion below can compare
        // accrual-time numbers.
        (uint256 owed0, uint256 owed1) = hook.keeperRewardOwed(keeper);
        vm.prank(keeper);
        hook.claimKeeperReward(keeper);
        (uint256 owedAfter0, uint256 owedAfter1) = hook.keeperRewardOwed(keeper);
        assertEq(owedAfter0, 0, "claim drained owed0");
        assertEq(owedAfter1, 0, "claim drained owed1");

        DirectionalLiquidityHook.ModeState memory postReb = hook.modeState(ModeRange.MODE_RIGHT);

        // The accumulator must have grown — the LP cut went there.
        assertGt(postReb.feePerShareCumulative0, preReb.feePerShareCumulative0, "lp cut t0 went to accum");

        // Verify keeper's cut matches keeperRewardBps within 1 wei. We
        // reconstruct the total fee from accumulator delta + keeper gain.
        uint256 keeperGain0 = token0.balanceOf(keeper) - keeperT0Before;
        uint256 keeperGain1 = token1.balanceOf(keeper) - keeperT1Before;
        // Sanity: claim payout matches the accrued owed amount.
        assertEq(keeperGain0, owed0, "claim paid out owed0");
        assertEq(keeperGain1, owed1, "claim paid out owed1");
        uint256 totalShares = uint256(preReb.totalShares);
        uint256 lpCut0 =
            (postReb.feePerShareCumulative0 - preReb.feePerShareCumulative0) * totalShares / (uint256(1) << 128);
        uint256 lpCut1 =
            (postReb.feePerShareCumulative1 - preReb.feePerShareCumulative1) * totalShares / (uint256(1) << 128);

        // total = keeper + lp; keeper / total ≈ keeperRewardBps / 10_000.
        // Use the equivalent integer-math identity to avoid div imprecision.
        if (keeperGain0 + lpCut0 > 0) {
            uint256 expected0 = (keeperGain0 + lpCut0) * KEEPER_REWARD_BPS / 10_000;
            assertApproxEqAbs(keeperGain0, expected0, 2, "keeper t0 share matches bps");
        }
        if (keeperGain1 + lpCut1 > 0) {
            uint256 expected1 = (keeperGain1 + lpCut1) * KEEPER_REWARD_BPS / 10_000;
            assertApproxEqAbs(keeperGain1, expected1, 2, "keeper t1 share matches bps");
        }
    }

    function test_fees_conservationAcrossTwoLPs() public {
        // Two LPs deposit the same amount BEFORE fees are generated, so
        // they share fees equally. Run identical swaps, both withdraw,
        // and verify the hook's residual ERC20 balance is dust — every
        // wei of fee was paid out to one of them.
        vm.warp(1_000);

        vm.prank(alice);
        uint256 aliceId = hook.deposit(ModeRange.MODE_RIGHT, 100e18, alice);
        vm.prank(bob);
        uint256 bobId = hook.deposit(ModeRange.MODE_RIGHT, 100e18, bob);

        _swapDownAndBack(2e18);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = hook.withdraw(aliceId, alice);
        vm.prank(bob);
        (uint256 b0, uint256 b1) = hook.withdraw(bobId, bob);

        // Equal shares, equal positions, equal entry → equal payouts within
        // v4 internal rounding (a few wei).
        assertApproxEqAbs(a0, b0, 5, "equal payouts t0");
        assertApproxEqAbs(a1, b1, 5, "equal payouts t1");

        // Mode reset; hook holds no residual.
        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_RIGHT);
        assertFalse(ms.initialized, "mode reset after both withdrew");
        assertLe(token0.balanceOf(address(hook)), 5, "no residual t0 in hook");
        assertLe(token1.balanceOf(address(hook)), 5, "no residual t1 in hook");
    }
}
