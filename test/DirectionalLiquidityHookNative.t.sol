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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DirectionalLiquidityHook} from "../src/DirectionalLiquidityHook.sol";
import {ModeRange} from "../src/libraries/ModeRange.sol";

/// @title DirectionalLiquidityHookNativeTest
/// @notice End-to-end coverage for the native-ETH branches of
///         `_settleFromPayer` and `_settleFromHook`. The pool here is
///         (ETH, ERC20), so currency0 is `address(0)` and Mode Left — the
///         mode whose position sits one bin RIGHT of price — pulls only
///         native ETH from the depositor and re-mints in native ETH on
///         every continuation rebalance.
/// @dev    Runs against a fresh PoolManager separate from the main hook
///         test fixture so the native-vs-ERC20 setup never collides with
///         tests that assume ERC20-only currencies.
contract DirectionalLiquidityHookNativeTest is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant EXPECTED_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;

    uint24 internal constant FEE = 10_000; // 1% LP fee → fees easy to detect on swap-driven tests
    uint24 internal constant BIN_WIDTH = 1;
    uint32 internal constant TWAP_WINDOW = 600;
    uint16 internal constant KEEPER_REWARD_BPS = 500; // 5%
    uint16 internal constant BUFFER_SIZE = 64;
    string internal constant NAME = "Directional Liquidity Position";
    string internal constant SYMBOL = "DLP";

    PoolManager internal manager;
    MockERC20 internal token1Erc20; // currency1 = ERC20; currency0 is native (address(0))
    Currency internal currency0; // native
    Currency internal currency1;
    PoolKey internal key;
    DirectionalLiquidityHook internal hook;
    PoolSwapTest internal swapRouter;

    address internal alice = makeAddr("alice");
    address internal swapper = makeAddr("swapper");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        manager = new PoolManager(address(this));

        token1Erc20 = new MockERC20("Token1", "T1", 18);
        currency0 = Currency.wrap(address(0)); // native ETH
        currency1 = Currency.wrap(address(token1Erc20));

        // Distinct prefix so deployment doesn't clobber the other test
        // contracts' hook addresses when run in the same forge invocation.
        address hookAddr = address(uint160(0x9999 << 144) | uint160(EXPECTED_FLAGS));
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
                NAME,
                SYMBOL
            ),
            hookAddr
        );
        hook = DirectionalLiquidityHook(payable(hookAddr));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        // Fund actors. Alice deposits, swapper executes swaps, keeper calls
        // rebalance and collects rewards.
        vm.deal(alice, 100 ether);
        vm.deal(swapper, 1_000 ether);
        token1Erc20.mint(swapper, 1_000_000 ether);
        vm.startPrank(swapper);
        token1Erc20.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- //
    // Helpers                                                          //
    // ---------------------------------------------------------------- //

    /// @dev Compute the exact native-ETH amount required to mint `liq`
    ///      units of liquidity at `[tickLower, tickUpper)` when the pool
    ///      spot is at-or-below `tickLower` (i.e. position is single-sided
    ///      currency0). Mirrors v4's `roundUp = true` ADD math so the
    ///      computed value matches what `modifyLiquidity` will charge.
    function _amount0ForAdd(int24 tickLower, int24 tickUpper, uint128 liq) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liq, true
        );
    }

    /// @dev Real swap. `targetTick` sets the price limit; `amountIn` caps
    ///      the spend. For zeroForOne=true (currency0 → currency1) the
    ///      caller forwards native ETH via `value`. For zeroForOne=false,
    ///      `value=0` and the swapper's currency1 ERC20 allowance is used.
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
        // For zeroForOne=true (selling currency0=ETH), forward msg.value;
        // for zeroForOne=false (selling currency1), no value needed.
        uint256 v = zeroForOne ? amountIn : 0;
        vm.prank(swapper);
        swapRouter.swap{value: v}(key, params, settings, bytes(""));
    }

    /// @dev Pile observations at `tick` for `steps × intervalSec` seconds so
    ///      `getTwap()` converges to that tick. Uses `_setPoolPriceAtTick`
    ///      to keep slot0 self-consistent (sqrtPriceX96 ↔ tick) — important
    ///      because subsequent swaps would otherwise see a stale price.
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

    /// @dev Coherent slot0 write (sqrtPrice + tick).
    function _setPoolPriceAtTick(int24 t) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        uint160 sqrt = TickMath.getSqrtPriceAtTick(t);
        uint256 packed = uint256(sqrt);
        packed |= uint256(uint24(t)) << 160;
        vm.store(address(manager), stateSlot, bytes32(packed));
    }

    // ---------------------------------------------------------------- //
    // Tests                                                            //
    // ---------------------------------------------------------------- //

    function test_native_modeLeftDeposit_pullsExactEthFromPayer() public {
        // Mode Left at tick 0 → range [60, 120); above active → pulls
        // currency0=ETH only. We pre-compute the exact ETH amount that
        // v4's roundUp ADD math will charge so we can send `msg.value`
        // exactly equal to it and verify zero residual on the hook.
        uint128 liq = 1e18;
        uint256 amt0 = _amount0ForAdd(60, 120, liq);
        assertGt(amt0, 0, "expected non-zero ETH amount for liq");

        uint256 aliceEthBefore = alice.balance;
        uint256 hookEthBefore = address(hook).balance;
        uint256 mgrEthBefore = address(manager).balance;

        vm.prank(alice);
        uint256 tokenId = hook.deposit{value: amt0}(ModeRange.MODE_LEFT, liq, alice);

        // Alice spent exactly amt0; hook holds no residual; manager
        // received the full amt0 (it's escrowed inside v4 against the new
        // position).
        assertEq(alice.balance, aliceEthBefore - amt0, "alice spent exactly amt0");
        assertEq(address(hook).balance, hookEthBefore, "hook holds no residual ETH");
        assertEq(address(manager).balance, mgrEthBefore + amt0, "manager escrowed amt0");

        // Mode state matches Mode-Left geometry.
        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_LEFT);
        assertTrue(ms.initialized, "mode initialized");
        assertEq(int256(ms.currentRangeLower), int256(60), "range lower");
        assertEq(int256(ms.currentRangeUpper), int256(120), "range upper");
        assertEq(uint256(ms.totalShares), uint256(liq), "1:1 init shares");

        // NFT minted to alice with fresh accumulator snapshot.
        assertEq(hook.ownerOf(tokenId), alice, "NFT owner = alice");
        DirectionalLiquidityHook.PositionInfo memory pos = hook.positionInfo(tokenId);
        assertEq(uint256(pos.mode), uint256(ModeRange.MODE_LEFT));
        assertEq(uint256(pos.shares), uint256(liq));
        assertEq(pos.feeSnapshot0, 0);
        assertEq(pos.feeSnapshot1, 0);
    }

    function test_native_modeLeftWithdraw_returnsEthToContractRecipient() public {
        // Round-trip a Mode-Left deposit and check that the principal
        // returns as native ETH to a CONTRACT recipient. v4's
        // `Currency.transfer` for native uses raw `call{value:}` with
        // empty calldata — verify it succeeds against a payable contract
        // (it would fail against a contract without `receive()` /
        // `fallback() payable`).
        EthReceiver sink = new EthReceiver();

        uint128 liq = 1e18;
        uint256 amt0 = _amount0ForAdd(60, 120, liq);
        vm.prank(alice);
        uint256 tokenId = hook.deposit{value: amt0}(ModeRange.MODE_LEFT, liq, alice);

        uint256 sinkBefore = address(sink).balance;
        vm.prank(alice);
        (uint256 a0, uint256 a1) = hook.withdraw(tokenId, address(sink));

        // Mode-Left at this point held only currency0 (no swap activity
        // happened), so principal returns as native ETH only.
        assertGt(a0, 0, "principal returned in currency0 (ETH)");
        assertEq(a1, 0, "no currency1 owed (position never crossed)");
        assertEq(address(sink).balance, sinkBefore + a0, "sink contract received exact ETH");

        // Mode reset on last-LP exit.
        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_LEFT);
        assertFalse(ms.initialized, "mode reset");
        assertEq(uint256(ms.totalShares), 0, "totalShares zeroed");
        // Hook holds no residual ETH after withdraw drained the manager.
        assertLe(address(hook).balance, 1, "hook ETH residual within rounding");
    }

    function test_native_keeperRebalance_paysEthRewardToKeeper() public {
        // Full keeper-reward exercise across BOTH currencies on a native
        // pool: deposit, drive a real round-trip swap that accrues fees in
        // both currency0 (ETH) and currency1 (ERC20), then drive TWAP past
        // the Mode-Left trigger and rebalance from a clean keeper EOA.
        // Verify the keeper receives both kinds of fees.
        uint128 liq = 100e18; // chunky so the swap has something to consume
        uint256 amt0 = _amount0ForAdd(60, 120, liq);
        vm.prank(alice);
        hook.deposit{value: amt0}(ModeRange.MODE_LEFT, liq, alice);

        // Initial buffer seed at the real (untampered) tick 0.
        vm.warp(1_000);
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}),
            BalanceDelta.wrap(0),
            bytes("")
        );

        // Up-leg: tick 0 → 200. Crosses [60,120) buying ETH for currency1 →
        // fees accrue in currency1 (the swap's input currency).
        vm.warp(1_500);
        _realSwap(200, 50e18);

        // Down-leg: tick 200 → -100. Crosses [120,60) selling ETH for
        // currency1 → fees accrue in ETH. Past tick 60 there's no
        // liquidity, so the swap glides freely down to the limit at -100,
        // moving slot0's spot tick into Mode-Left's trigger zone.
        vm.warp(2_000);
        _realSwap(-100, 200 ether);

        (, int24 postSwapTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLt(int256(postSwapTick), int256(0), "real swap drove tick negative");

        // Pile observations so TWAP < 0 (Mode-Left trigger: twap < lower - bin = 0).
        _seedTwapAt(postSwapTick, 12, 60);
        int24 twap = hook.getTwap();
        assertLt(int256(twap), int256(0), "TWAP crossed trigger");

        // Snapshot keeper balances before the rebalance.
        uint256 keeperEthBefore = keeper.balance;
        uint256 keeperT1Before = token1Erc20.balanceOf(keeper);

        vm.prank(keeper);
        hook.rebalance();

        // Range shifted (geometric assertion separate from value flow):
        // Mode-Left at TWAP=postSwapTick → activeBin one bin to the right.
        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_LEFT);
        assertTrue(after_.initialized, "still initialized");
        assertEq(uint256(after_.totalShares), uint256(liq), "totalShares preserved");
        // Strictly different from the original [60, 120).
        assertTrue(
            after_.currentRangeLower != int24(60) || after_.currentRangeUpper != int24(120),
            "range shifted"
        );

        // Pull-pattern reward: rebalance credits the keeper's escrow,
        // not their wallet. Verify both currencies are owed, then claim.
        (uint256 owed0, uint256 owed1) = hook.keeperRewardOwed(keeper);
        assertGt(owed0, 0, "keeper owed ETH reward");
        assertGt(owed1, 0, "keeper owed currency1 reward");

        vm.prank(keeper);
        hook.claimKeeperReward(keeper);

        // After the claim, the wallet receives both currencies.
        assertEq(keeper.balance - keeperEthBefore, owed0, "keeper claimed ETH reward");
        assertEq(token1Erc20.balanceOf(keeper) - keeperT1Before, owed1, "keeper claimed currency1 reward");
    }

    function test_native_overpaidDepositRefundsExcess() public {
        // F-3 from docs/self-audit.md: native-ETH overpayment must be
        // refunded to the payer rather than silently retained by the
        // hook. Send 1 ether more than v4 needs and verify alice nets
        // exactly the principal.
        uint128 liq = 1e18;
        uint256 amt0 = _amount0ForAdd(60, 120, liq);
        uint256 sent = amt0 + 1 ether;

        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        hook.deposit{value: sent}(ModeRange.MODE_LEFT, liq, alice);

        // Net spend = exactly amt0 (the rest came back as a refund).
        assertEq(alice.balance, aliceEthBefore - amt0, "alice refunded excess");
        // Hook holds no residual — what came in either went to the
        // manager (as principal) or back to alice (as refund).
        assertEq(address(hook).balance, 0, "no residual ETH on hook");
    }

    function test_native_overpaidDepositReverts_whenPayerRejectsRefund() public {
        // Adversarial: a contract payer whose receive/fallback reverts
        // would otherwise leave the hook with an unrecoverable balance.
        // Refund must propagate via `RefundFailed` so the deposit
        // unwinds atomically.
        EthRejecter rejecter = new EthRejecter();
        vm.deal(address(rejecter), 100 ether);

        uint128 liq = 1e18;
        uint256 amt0 = _amount0ForAdd(60, 120, liq);

        // Calling through the rejecter causes the hook to attempt a
        // refund of the 1-wei overpayment — which the rejecter rejects.
        vm.expectRevert(DirectionalLiquidityHook.RefundFailed.selector);
        rejecter.deposit{value: amt0 + 1}(hook, liq);

        // Hook is back to clean state.
        assertEq(address(hook).balance, 0, "hook unwound");
        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_LEFT);
        assertFalse(ms.initialized, "mode not initialized after revert");
    }

    function test_native_exactPaymentRequiresNoRefund() public {
        // Sanity guard against an off-by-one regression: when msg.value
        // equals the v4-required amount exactly, the refund branch
        // must NOT fire (it would mean a 0-value send to the payer,
        // which is fine but wasted gas). Verify the deposit succeeds
        // and the hook holds no residual.
        uint128 liq = 1e18;
        uint256 amt0 = _amount0ForAdd(60, 120, liq);

        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        hook.deposit{value: amt0}(ModeRange.MODE_LEFT, liq, alice);

        assertEq(alice.balance, aliceEthBefore - amt0, "exact payment, no refund needed");
        assertEq(address(hook).balance, 0, "no residual ETH");
    }

    function test_native_maliciousKeeperCannotDosRebalance() public {
        // F-4 from docs/self-audit.md: with the push-pattern reward, a
        // keeper contract whose receive() reverts would cause every
        // rebalance it triggers to revert too — denying everyone else
        // their rebalance until a different keeper called. The pull-
        // pattern isolates that failure to the malicious keeper alone:
        // the rebalance commits, the LP accumulator updates, and the
        // malicious keeper's reward sits in escrow (claim will revert
        // for them, but no one else cares).

        uint128 liq = 100e18;
        uint256 amt0 = _amount0ForAdd(60, 120, liq);
        vm.prank(alice);
        hook.deposit{value: amt0}(ModeRange.MODE_LEFT, liq, alice);

        vm.warp(1_000);
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}),
            BalanceDelta.wrap(0),
            bytes("")
        );

        vm.warp(1_500);
        _realSwap(200, 50e18);
        vm.warp(2_000);
        _realSwap(-100, 200 ether);

        (, int24 postSwapTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        _seedTwapAt(postSwapTick, 12, 60);

        // The "malicious" keeper is a contract that reverts on incoming
        // ETH. Under push-pattern, this would brick the rebalance.
        EthRejecter badKeeper = new EthRejecter();
        DirectionalLiquidityHook.ModeState memory before_ = hook.modeState(ModeRange.MODE_LEFT);

        // Rebalance triggered by the bad keeper succeeds (the unlock
        // doesn't try to send ETH to them inline).
        vm.prank(address(badKeeper));
        hook.rebalance();

        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_LEFT);
        assertTrue(
            after_.currentRangeLower != before_.currentRangeLower
                || after_.currentRangeUpper != before_.currentRangeUpper,
            "rebalance committed despite reverting keeper"
        );

        // The bad keeper does have a reward owed — it just can't claim
        // it. That's the keeper's own problem, not anyone else's.
        (uint256 owed0,) = hook.keeperRewardOwed(address(badKeeper));
        assertGt(owed0, 0, "bad keeper has accrued reward in escrow");
        vm.prank(address(badKeeper));
        vm.expectRevert(); // raw call into receive() reverts via NativeTransferFailed
        hook.claimKeeperReward(address(badKeeper));

        // ...but they can claim to a benign address. Pull-pattern lets
        // the keeper recover by directing the payout elsewhere.
        EthReceiver sink = new EthReceiver();
        vm.prank(address(badKeeper));
        hook.claimKeeperReward(address(sink));
        assertGt(address(sink).balance, 0, "sink received the reward");
    }

    function test_native_underpaidDepositReverts() public {
        // Spec/sanity: if `msg.value` is less than the v4-required amount,
        // the hook's `poolManager.settle{value: amount}()` cannot draw the
        // full settlement from the hook's native balance and the call
        // reverts on EVM out-of-funds. The hook doesn't (and shouldn't)
        // wrap this in a custom error — letting v4's revert propagate is
        // the graceful failure mode.
        uint128 liq = 1e18;
        uint256 amt0 = _amount0ForAdd(60, 120, liq);
        // Send 1 wei when v4 needs ~3e15. The settle inside the unlock
        // callback will try to forward `amt0` from the hook's balance and
        // fail.
        assertGt(amt0, 1, "sanity: real charge exceeds the underpayment");

        vm.prank(alice);
        vm.expectRevert();
        hook.deposit{value: 1}(ModeRange.MODE_LEFT, liq, alice);

        // Mode stays uninitialized because the unlock callback reverted.
        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_LEFT);
        assertFalse(ms.initialized, "mode not initialized after revert");
    }
}

/// @dev Tiny payable contract used to verify that the hook's withdraw path
///      can deliver native ETH to a CONTRACT recipient (the call uses raw
///      `call{value:}` and fails against contracts without a payable
///      receive/fallback).
contract EthReceiver {
    receive() external payable {}
}

/// @dev A contract that REJECTS incoming ETH. Used to drive the refund
///      failure path: when a payer's receive/fallback reverts, the
///      hook's refund attempt must propagate `RefundFailed` so the
///      deposit unwinds rather than silently retaining the overage.
contract EthRejecter {
    function deposit(DirectionalLiquidityHook hook, uint128 liq) external payable {
        hook.deposit{value: msg.value}(ModeRange.MODE_LEFT, liq, address(this));
    }

    receive() external payable {
        revert("nope");
    }
}
