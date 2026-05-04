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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DirectionalLiquidityHook} from "../src/DirectionalLiquidityHook.sol";
import {ModeRange} from "../src/libraries/ModeRange.sol";

/// @title DirectionalLiquidityHookTest — step 1 (skeleton)
/// @notice Initialization-only tests for the skeleton hook.
contract DirectionalLiquidityHookTest is Test {
    using StateLibrary for IPoolManager;

    // Permission flags this hook must encode in its address.
    uint160 internal constant EXPECTED_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;

    // Constructor params we'll reuse across tests.
    uint24 internal constant BIN_WIDTH = 1; // multiples of tickSpacing
    uint32 internal constant TWAP_WINDOW = 600; // 10 minutes
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
    address internal swapper = makeAddr("swapper");

    function setUp() public {
        manager = new PoolManager(address(this));

        // Two ERC20s, sorted so currency0 < currency1.
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Pre-pick an address with the right permission bits. Using a high
        // bit avoids the precompile range and any deployed contract.
        address hookAddr = address(uint160(0x4444 << 144) | uint160(EXPECTED_FLAGS));

        // Build the PoolKey with the hook address baked in (the constructor
        // requires `_poolKey.hooks == this`).
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // Deploy the hook bytecode at hookAddr; the constructor runs in-place.
        deployCodeTo(
            "DirectionalLiquidityHook.sol:DirectionalLiquidityHook",
            abi.encode(
                IPoolManager(address(manager)), key, BIN_WIDTH, TWAP_WINDOW, KEEPER_REWARD_BPS, BUFFER_SIZE, NAME, SYMBOL
            ),
            hookAddr
        );
        hook = DirectionalLiquidityHook(payable(hookAddr));

        // Initialize the pool at sqrt(1) so the spot tick is 0 — easy mental
        // model for the geometry checks below. PoolManager rejects the call
        // unless the pool key matches what the hook validates against, which
        // is exactly `key` (validation happens via _requireOurPool only on
        // hook callbacks; init itself doesn't trigger any callback for us).
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Fund Alice and approve the hook to pull tokens.
        token0.mint(alice, 1_000_000 ether);
        token1.mint(alice, 1_000_000 ether);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // Swap router fixture (PoolSwapTest from v4-core). Used by every
        // test that wants real swaps to hit `_afterSwap` and move slot0.
        // The swapper is a separate address that funds the swaps; it
        // approves the router instead of the hook.
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        token0.mint(swapper, 1_000_000 ether);
        token1.mint(swapper, 1_000_000 ether);
        vm.startPrank(swapper);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- //
    // Initialization                                                   //
    // ---------------------------------------------------------------- //

    // ---------------------------------------------------------------- //
    // Constructor bound checks                                         //
    // ---------------------------------------------------------------- //

    function test_constructor_revertsOnTinyBufferSize() public {
        // bufferSize = 4 is below MIN_BUFFER_SIZE (8) — must revert.
        // Use the same hookAddr so we hit our deployment path (the
        // address must still encode the right flags).
        address hookAddr = address(uint160(0x6666 << 144) | uint160(EXPECTED_FLAGS));
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        vm.expectRevert(bytes("bufferSize < MIN_BUFFER_SIZE"));
        deployCodeTo(
            "DirectionalLiquidityHook.sol:DirectionalLiquidityHook",
            abi.encode(IPoolManager(address(manager)), k, BIN_WIDTH, TWAP_WINDOW, KEEPER_REWARD_BPS, uint16(4), NAME, SYMBOL),
            hookAddr
        );
    }

    function test_constructor_revertsOnOversizedBinTicks() public {
        // binWidth × tickSpacing must be ≤ MAX_BIN_TICKS (= MAX_TICK / 2).
        // Pick a combination that just exceeds the bound: binWidth=10_000,
        // tickSpacing=60 → 600_000 > 443_636.
        address hookAddr = address(uint160(0x7777 << 144) | uint160(EXPECTED_FLAGS));
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        vm.expectRevert(bytes("binTicks > MAX_BIN_TICKS"));
        deployCodeTo(
            "DirectionalLiquidityHook.sol:DirectionalLiquidityHook",
            abi.encode(
                IPoolManager(address(manager)), k, uint24(10_000), TWAP_WINDOW, KEEPER_REWARD_BPS, BUFFER_SIZE, NAME, SYMBOL
            ),
            hookAddr
        );
    }

    function test_init_addressEncodesPermissions() public view {
        // Bottom 14 bits of the deployed address must equal the flag set.
        uint160 lowBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(lowBits, EXPECTED_FLAGS, "hook address does not encode expected permissions");
    }

    function test_init_immutables() public view {
        assertEq(address(hook.poolManager()), address(manager), "poolManager mismatch");
        assertEq(Currency.unwrap(hook.currency0()), Currency.unwrap(currency0), "currency0 mismatch");
        assertEq(Currency.unwrap(hook.currency1()), Currency.unwrap(currency1), "currency1 mismatch");
        assertEq(uint256(hook.fee()), uint256(key.fee), "fee mismatch");
        assertEq(int256(hook.tickSpacing()), int256(key.tickSpacing), "tickSpacing mismatch");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()), "poolId mismatch");

        assertEq(uint256(hook.binWidth()), uint256(BIN_WIDTH), "binWidth mismatch");
        assertEq(uint256(hook.twapWindow()), uint256(TWAP_WINDOW), "twapWindow mismatch");
        assertEq(uint256(hook.keeperRewardBps()), uint256(KEEPER_REWARD_BPS), "keeperRewardBps mismatch");
        assertEq(uint256(hook.bufferSize()), uint256(BUFFER_SIZE), "bufferSize mismatch");

        // Reconstructed PoolKey round-trips back to the same id.
        PoolKey memory reconstructed = hook.poolKey();
        assertEq(PoolId.unwrap(reconstructed.toId()), PoolId.unwrap(key.toId()), "reconstructed key id mismatch");
        assertEq(address(reconstructed.hooks), address(hook), "reconstructed hooks mismatch");
    }

    function test_init_erc721Metadata() public view {
        assertEq(hook.name(), NAME, "ERC721 name mismatch");
        assertEq(hook.symbol(), SYMBOL, "ERC721 symbol mismatch");
    }

    function test_init_modesUninitialized() public view {
        for (uint8 m = 0; m < 3; m++) {
            DirectionalLiquidityHook.ModeState memory s = hook.modeState(m);
            assertEq(s.initialized, false, "mode wrongly initialized at deploy");
            assertEq(uint256(s.totalShares), 0, "mode totalShares non-zero at deploy");
            assertEq(int256(s.currentRangeLower), 0, "currentRangeLower non-zero at deploy");
            assertEq(int256(s.currentRangeUpper), 0, "currentRangeUpper non-zero at deploy");
            assertEq(s.feePerShareCumulative0, 0, "feePerShareCumulative0 non-zero at deploy");
            assertEq(s.feePerShareCumulative1, 0, "feePerShareCumulative1 non-zero at deploy");
            assertEq(s.lastShiftDir, false, "lastShiftDir non-zero at deploy");
        }
    }

    // ---------------------------------------------------------------- //
    // Permissions                                                      //
    // ---------------------------------------------------------------- //

    // ---------------------------------------------------------------- //
    // TWAP buffer                                                      //
    // ---------------------------------------------------------------- //

    function test_twap_revertsWhenNoObservations() public {
        vm.expectRevert(DirectionalLiquidityHook.NoObservations.selector);
        hook.getTwap();
    }

    function test_twap_seedsBufferOnFirstAfterSwap() public {
        _setSlot0Tick(100);
        vm.warp(1_000);
        _callAfterSwap();

        assertEq(hook.observationCount(), 1, "count should be 1");
        assertEq(hook.observationIndex(), 0, "head should be slot 0");

        DirectionalLiquidityHook.Observation memory o = hook.getObservation(0);
        assertEq(uint256(o.timestamp), 1_000);
        assertEq(int256(o.tick), int256(100));
        assertEq(int256(o.tickCumulative), 0);
    }

    function test_twap_warmupReturnsSpotTick() public {
        // Single observation; window not yet covered → fall back to spot.
        _setSlot0Tick(42);
        vm.warp(10_000);
        _callAfterSwap();

        assertEq(int256(hook.getTwap()), int256(42), "warmup should return spot tick");
    }

    function test_twap_advancesCumulativeAcrossObservations() public {
        // Two observations 60s apart at ticks 100 and 200.
        _setSlot0Tick(100);
        vm.warp(1_000);
        _callAfterSwap(); // o0: ts=1000, tick=100, cum=0

        _setSlot0Tick(200);
        vm.warp(1_060);
        _callAfterSwap(); // o1: ts=1060, tick=200, cum = 0 + 100*60 = 6000

        DirectionalLiquidityHook.Observation memory o1 = hook.getObservation(1);
        assertEq(uint256(o1.timestamp), 1_060);
        assertEq(int256(o1.tick), int256(200));
        assertEq(int256(o1.tickCumulative), int256(6_000));
    }

    function test_twap_sameSecondOverwritesHead() public {
        _setSlot0Tick(100);
        vm.warp(1_000);
        _callAfterSwap();

        _setSlot0Tick(150); // tick moved within the same block
        _callAfterSwap();

        // Still one observation, but tick updated.
        assertEq(hook.observationCount(), 1, "same-second writes must not grow buffer");
        DirectionalLiquidityHook.Observation memory o = hook.getObservation(0);
        assertEq(int256(o.tick), int256(150));
        assertEq(int256(o.tickCumulative), 0); // no time elapsed since seed
    }

    function test_twap_interpolatesWithinFullyCoveredWindow() public {
        // Build: tick=0 from t=1000..1600, then tick=120 from t=1600..2200.
        // TWAP_WINDOW = 600s. Querying at t=2200 with window=600 covers
        // exactly the second leg → expected mean tick = 120.
        _setSlot0Tick(0);
        vm.warp(1_000);
        _callAfterSwap();

        _setSlot0Tick(120);
        vm.warp(1_600);
        _callAfterSwap();

        // Add a third observation matching tick=120 at t=2200 so the window
        // is fully bracketed by real observations.
        _setSlot0Tick(120);
        vm.warp(2_200);
        _callAfterSwap();

        // Window = [1600, 2200]. tickCumulative grows by 120 * 600 over the
        // window → mean tick = 120.
        assertEq(int256(hook.getTwap()), int256(120), "TWAP across constant leg");
    }

    function test_twap_ringBufferWraparound() public {
        // bufferSize = 64. Push 70 observations 1s apart → ring should wrap
        // and `count` should saturate at 64 with `head` pointing to the
        // newest write.
        _setSlot0Tick(7);
        for (uint256 i = 0; i < 70; i++) {
            vm.warp(1_000 + i);
            _callAfterSwap();
        }

        assertEq(hook.observationCount(), 64, "count should saturate at bufferSize");
        // After 70 writes (0..69), index advances 0,1,...,63,0,1,2,3,4,5
        // → head should be at slot 5.
        assertEq(hook.observationIndex(), 5, "head slot after wraparound");
    }

    function test_twap_hookOnlyCallableByPoolManager() public {
        // Adversarial: anyone other than the PoolManager calling afterSwap
        // must revert (NotPoolManager from BaseHook).
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(); // BaseHook.NotPoolManager()
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
    }

    // ---------------------------------------------------------------- //
    // Helpers                                                          //
    // ---------------------------------------------------------------- //

    /// @dev Mints both tokens to a fresh address and approves the hook.
    function _bobWithFunds() internal returns (address bob) {
        bob = makeAddr("bob");
        token0.mint(bob, 1_000_000 ether);
        token1.mint(bob, 1_000_000 ether);
        vm.startPrank(bob);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Writes the desired tick into the PoolManager's `slot0` for our
    ///      pool. Only the tick field matters for these tests; sqrtPriceX96
    ///      is set to 1 to look "initialized".
    function _setSlot0Tick(int24 t) internal {
        // PoolManager pools mapping is at storage slot 6 (StateLibrary.POOLS_SLOT).
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        // Pack: bits 0..159 = sqrtPriceX96, 160..183 = tick (24-bit two's complement),
        //       184..207 = protocolFee, 208..231 = lpFee.
        uint256 packed = uint256(1); // sqrtPriceX96 = 1
        packed |= uint256(uint24(t)) << 160;
        vm.store(address(manager), stateSlot, bytes32(packed));
    }

    /// @dev Writes both sqrtPriceX96 AND tick into slot0 in a self-consistent
    ///      way. Use this when subsequent calls into `modifyLiquidity` need
    ///      the price math to be coherent with the tick (otherwise v4
    ///      computes amount0/amount1 from a sqrtPrice that disagrees with
    ///      the tick we faked).
    function _setPoolPriceAtTick(int24 t) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        uint160 sqrt = TickMath.getSqrtPriceAtTick(t);
        uint256 packed = uint256(sqrt);
        packed |= uint256(uint24(t)) << 160;
        vm.store(address(manager), stateSlot, bytes32(packed));
    }

    /// @dev Calls `hook.afterSwap` as if from the PoolManager. The hook
    ///      reads the current tick from `slot0` of the manager via
    ///      `extsload`, so set the tick first via `_setSlot0Tick`.
    function _callAfterSwap() internal {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
    }

    // ---------------------------------------------------------------- //
    // First-deposit (Mode Right)                                       //
    // ---------------------------------------------------------------- //

    function test_deposit_revertsOnInvalidMode() public {
        vm.prank(alice);
        vm.expectRevert(DirectionalLiquidityHook.InvalidMode.selector);
        hook.deposit(99, 1 ether, alice);
    }

    function test_deposit_revertsOnZeroLiquidity() public {
        vm.prank(alice);
        vm.expectRevert(DirectionalLiquidityHook.ZeroLiquidity.selector);
        hook.deposit(ModeRange.MODE_RIGHT, 0, alice);
    }

    function test_deposit_modeRight_initializesAndMintsNFT() public {
        // Pool spot tick = 0; binTicks = binWidth × tickSpacing = 1 × 60 = 60.
        // Active bin = [0, 60). Mode Right sits one bin LEFT → [-60, 0).
        uint128 liq = 1e18;

        uint256 a0Before = token0.balanceOf(alice);
        uint256 a1Before = token1.balanceOf(alice);

        vm.prank(alice);
        uint256 tokenId = hook.deposit(ModeRange.MODE_RIGHT, liq, alice);

        // NFT minted to alice, state recorded.
        assertEq(hook.ownerOf(tokenId), alice, "NFT owner");
        assertEq(uint256(tokenId), 1, "first tokenId is 1");

        DirectionalLiquidityHook.PositionInfo memory pos = hook.positionInfo(tokenId);
        assertEq(uint256(pos.mode), uint256(ModeRange.MODE_RIGHT), "position mode");
        assertEq(uint256(pos.shares), uint256(liq), "1:1 shares on first deposit");
        assertEq(pos.feeSnapshot0, 0, "fresh accumulator snapshot");
        assertEq(pos.feeSnapshot1, 0, "fresh accumulator snapshot");

        // Mode state: range is [-60, 0), totalShares=liq, initialized=true.
        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_RIGHT);
        assertEq(int256(ms.currentRangeLower), int256(-60), "range lower");
        assertEq(int256(ms.currentRangeUpper), int256(0), "range upper");
        assertEq(uint256(ms.totalShares), uint256(liq), "totalShares");
        assertTrue(ms.initialized, "mode initialized");

        // Mode Right is entirely below the active tick. Below-active range
        // requires only currency1 to be deposited (token0 stays at 0 owed).
        // Verify: alice's token0 balance unchanged, token1 strictly less.
        assertEq(token0.balanceOf(alice), a0Before, "no token0 should be pulled for below-active range");
        assertLt(token1.balanceOf(alice), a1Before, "some token1 should have been pulled");

        // The pool received the tokens.
        assertEq(token1.balanceOf(address(manager)), a1Before - token1.balanceOf(alice), "manager received token1");
    }

    function test_deposit_modeRight_secondDepositMintsProRataShares() public {
        // First deposit: 1e18 liq → 1e18 shares (1:1 init).
        vm.startPrank(alice);
        uint256 id1 = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        // Second deposit: same liq again → identical shares (no fees yet).
        uint256 id2 = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        vm.stopPrank();

        assertEq(uint256(id2), uint256(id1) + 1, "tokenIds increment");

        DirectionalLiquidityHook.PositionInfo memory p1 = hook.positionInfo(id1);
        DirectionalLiquidityHook.PositionInfo memory p2 = hook.positionInfo(id2);
        assertEq(uint256(p2.shares), uint256(p1.shares), "second deposit pro-rata = same shares");

        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_RIGHT);
        assertEq(uint256(ms.totalShares), 2e18, "totalShares accumulates");
    }

    function test_deposit_recipientCanDifferFromPayer() public {
        address bob = makeAddr("bob");
        vm.prank(alice);
        uint256 tokenId = hook.deposit(ModeRange.MODE_RIGHT, 1e18, bob);
        assertEq(hook.ownerOf(tokenId), bob, "NFT goes to recipient, payer pays");
    }

    function test_deposit_unlockCallback_onlyByPoolManager() public {
        // Adversarial: anyone other than the PoolManager must not be able
        // to invoke the unlock callback directly.
        vm.expectRevert(DirectionalLiquidityHook.NotPoolManagerUnlock.selector);
        hook.unlockCallback(bytes(""));
    }

    // ---------------------------------------------------------------- //
    // Withdraw                                                         //
    // ---------------------------------------------------------------- //

    function test_withdraw_revertsWhenNotOwner() public {
        vm.prank(alice);
        uint256 tokenId = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);

        address mallory = makeAddr("mallory");
        vm.prank(mallory);
        vm.expectRevert(DirectionalLiquidityHook.NotPositionOwner.selector);
        hook.withdraw(tokenId, mallory);
    }

    function test_withdraw_revertsForNonexistentToken() public {
        vm.prank(alice);
        vm.expectRevert(DirectionalLiquidityHook.NotPositionOwner.selector);
        hook.withdraw(999, alice);
    }

    function test_withdraw_lastLP_returnsAllPrincipalAndResetsMode() public {
        // Deposit, then immediately withdraw — no fees, just principal round-trip.
        uint256 token1Before = token1.balanceOf(alice);
        uint256 token0Before = token0.balanceOf(alice);

        vm.startPrank(alice);
        uint256 tokenId = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        (uint256 a0Out, uint256 a1Out) = hook.withdraw(tokenId, alice);
        vm.stopPrank();

        // Mode-Right is below active → only currency1 was pulled and returned.
        assertEq(a0Out, 0, "no currency0 owed back");
        assertGt(a1Out, 0, "currency1 returned");

        // Round-trip is exact (no fees) up to v4 internal rounding (off by 1 wei
        // is acceptable on a single deposit/withdraw pair).
        assertApproxEqAbs(token1.balanceOf(alice), token1Before, 1, "token1 round-trip");
        assertEq(token0.balanceOf(alice), token0Before, "token0 untouched");

        // Mode state cleared (last-LP cleanup, spec §5.3.9).
        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_RIGHT);
        assertFalse(ms.initialized, "mode reset after last LP exit");
        assertEq(uint256(ms.totalShares), 0, "totalShares zeroed");
        assertEq(int256(ms.currentRangeLower), 0, "range zeroed");
        assertEq(int256(ms.currentRangeUpper), 0, "range zeroed");

        // NFT burned.
        vm.expectRevert();
        hook.ownerOf(tokenId);
    }

    function test_withdraw_twoLPsInTwoOut_resetsModeCleanly() public {
        // Two LPs deposit, both withdraw. After the second exit, the mode
        // must be back to a fully-reset state.
        address bob = _bobWithFunds();

        vm.prank(alice);
        uint256 aliceId = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        vm.prank(bob);
        uint256 bobId = hook.deposit(ModeRange.MODE_RIGHT, 1e18, bob);

        vm.prank(alice);
        hook.withdraw(aliceId, alice);
        vm.prank(bob);
        hook.withdraw(bobId, bob);

        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_RIGHT);
        assertFalse(ms.initialized, "mode reset");
        assertEq(uint256(ms.totalShares), 0, "totalShares zeroed");

        // Both LPs got back close to their deposit amounts in token1.
        assertApproxEqAbs(token1.balanceOf(alice), 1_000_000 ether, 1, "alice round-trip");
        assertApproxEqAbs(token1.balanceOf(bob), 1_000_000 ether, 1, "bob round-trip");
    }

    function test_withdraw_partialWithdrawalLeavesModeIntact() public {
        // Two LPs deposit; first withdraws → mode stays initialized.
        address bob = _bobWithFunds();

        vm.prank(alice);
        uint256 aliceId = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        vm.prank(bob);
        hook.deposit(ModeRange.MODE_RIGHT, 1e18, bob);

        vm.prank(alice);
        hook.withdraw(aliceId, alice);

        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_RIGHT);
        assertTrue(ms.initialized, "mode still initialized with one LP remaining");
        assertEq(uint256(ms.totalShares), 1e18, "totalShares = bob's shares");
    }

    function test_withdraw_thenRedeposit_reInitializesMode() public {
        // Last-LP exit must be cleanly re-initializable. Spec §7.5.
        vm.startPrank(alice);
        uint256 id = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        hook.withdraw(id, alice);
        // Re-deposit immediately should follow the first-deposit path.
        uint256 id2 = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        vm.stopPrank();

        DirectionalLiquidityHook.ModeState memory ms = hook.modeState(ModeRange.MODE_RIGHT);
        assertTrue(ms.initialized, "re-init on re-deposit");
        assertEq(uint256(ms.totalShares), 1e18, "fresh 1:1 init");

        // Snapshot on the new NFT must be 0 (accumulator reset).
        DirectionalLiquidityHook.PositionInfo memory p2 = hook.positionInfo(id2);
        assertEq(p2.feeSnapshot0, 0);
        assertEq(p2.feeSnapshot1, 0);
    }

    function test_withdraw_recipientCanDifferFromOwner() public {
        address sink = makeAddr("sink");
        vm.startPrank(alice);
        uint256 id = hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        uint256 token1Sink = token1.balanceOf(sink);
        hook.withdraw(id, sink);
        vm.stopPrank();
        assertGt(token1.balanceOf(sink), token1Sink, "proceeds delivered to sink");
    }

    // ---------------------------------------------------------------- //
    // Rebalance                                                        //
    // ---------------------------------------------------------------- //

    function test_rebalance_revertsWhenNoModesInitialized() public {
        // Even with TWAP observations, no initialized mode → revert.
        _setSlot0Tick(0);
        vm.warp(1_000);
        _callAfterSwap();
        vm.expectRevert(DirectionalLiquidityHook.NothingToRebalance.selector);
        hook.rebalance();
    }

    function test_rebalance_revertsWhenNoTrigger() public {
        // Mode initialized but TWAP hasn't moved → no shift needed.
        vm.prank(alice);
        hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        // Seed an observation at tick 0.
        _setSlot0Tick(0);
        vm.warp(2_000);
        _callAfterSwap();
        vm.expectRevert(DirectionalLiquidityHook.NothingToRebalance.selector);
        hook.rebalance();
    }

    function test_rebalance_modeRight_shiftsRangeOnTrigger() public {
        // First deposit at tick 0 → range [-60, 0).
        vm.prank(alice);
        hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);

        // Move TWAP rightward enough to trigger Mode Right shift. Trigger
        // is `twap >= rangeUpper + binTicks = 0 + 60 = 60`. We push tick
        // to 200 and seed enough observations so getTwap returns ≥ 60.
        _setSlot0Tick(200);
        vm.warp(10_000);
        _callAfterSwap();
        vm.warp(10_000 + TWAP_WINDOW + 1); // window covered
        _callAfterSwap();

        // Move pool's actual sqrtPrice/tick state too — the rebalance reads
        // current tick to know which currency the burned principal arrives
        // in. Expected new range (one bin behind tick 200) = [120, 180).
        _setPoolPriceAtTick(200);

        // Capture mode state pre-rebalance.
        DirectionalLiquidityHook.ModeState memory before_ = hook.modeState(ModeRange.MODE_RIGHT);
        assertEq(int256(before_.currentRangeLower), int256(-60));

        // Anyone may call rebalance.
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        hook.rebalance();

        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_RIGHT);
        assertEq(int256(after_.currentRangeLower), int256(120), "shifted to new bin");
        assertEq(int256(after_.currentRangeUpper), int256(180), "shifted to new bin");
        assertEq(uint256(after_.totalShares), uint256(before_.totalShares), "totalShares unchanged");
        assertTrue(after_.initialized, "still initialized");
    }

    function test_rebalance_modeLeft_shiftsRangeOnLeftTrigger() public {
        // Set the pool tick high so first-deposit Mode Left places its
        // position above active. Active bin around 0 = [0, 60). Mode Left
        // = [60, 120). Then move TWAP leftward enough to trigger.
        vm.prank(alice);
        hook.deposit(ModeRange.MODE_LEFT, 1e18, alice);

        _setSlot0Tick(-200);
        vm.warp(10_000);
        _callAfterSwap();
        vm.warp(10_000 + TWAP_WINDOW + 1);
        _callAfterSwap();
        _setPoolPriceAtTick(-200);

        hook.rebalance();

        // New range: one bin behind tick -200 = [-180, -120) → Mode Left
        // sits one bin RIGHT = [-180+? wait]. Active bin at -200 = [-240, -180).
        // Mode Left = active upper..active upper+bin = [-180, -120).
        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_LEFT);
        assertEq(int256(after_.currentRangeLower), int256(-180));
        assertEq(int256(after_.currentRangeUpper), int256(-120));
    }

    function test_rebalance_modeBoth_continuationKeepsDir() public {
        vm.prank(alice);
        hook.deposit(ModeRange.MODE_BOTH, 1e18, alice);
        // Initial Both/dir=false at tick 0 → range [-60, 0).
        DirectionalLiquidityHook.ModeState memory init = hook.modeState(ModeRange.MODE_BOTH);
        assertEq(int256(init.currentRangeLower), int256(-60));
        assertFalse(init.lastShiftDir, "init dir = false");

        // Push TWAP rightward → continuation.
        _setSlot0Tick(200);
        vm.warp(10_000);
        _callAfterSwap();
        vm.warp(10_000 + TWAP_WINDOW + 1);
        _callAfterSwap();
        _setPoolPriceAtTick(200);

        hook.rebalance();

        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_BOTH);
        assertEq(int256(after_.currentRangeLower), int256(120), "continuation: shifted right");
        assertFalse(after_.lastShiftDir, "dir unchanged on continuation");
    }

    // Mode-Both reversal end-to-end lives below in the swap-driven
    // section (`test_swapDriven_modeBoth_reversalEndToEnd`). It can't be
    // unit-tested with vm.store-faked tick movement: a faked tick leaves
    // the v4 position's underlying tokens out of sync with the pool's
    // reserves, so the burn returns the wrong currency. The reversal
    // trigger geometry is independently unit-tested in
    // ModeRange.t.sol::test_nextTarget_modeBothReversalFlipsDir.

    function test_rebalance_batchHandlesMultipleModesInOneUnlock() public {
        // Two modes initialized; rebalance shifts both in one unlock.
        vm.startPrank(alice);
        hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        hook.deposit(ModeRange.MODE_LEFT, 1e18, alice);
        vm.stopPrank();

        // TWAP can only fire one direction at a time; choose rightward and
        // verify only Mode Right shifts (Mode Left's leftward trigger
        // doesn't fire). Then check both modes still in valid state.
        _setSlot0Tick(200);
        vm.warp(10_000);
        _callAfterSwap();
        vm.warp(10_000 + TWAP_WINDOW + 1);
        _callAfterSwap();
        _setPoolPriceAtTick(200);

        hook.rebalance();

        DirectionalLiquidityHook.ModeState memory r = hook.modeState(ModeRange.MODE_RIGHT);
        DirectionalLiquidityHook.ModeState memory l = hook.modeState(ModeRange.MODE_LEFT);
        assertEq(int256(r.currentRangeLower), int256(120), "Mode Right shifted");
        assertEq(int256(l.currentRangeLower), int256(60), "Mode Left untouched");
    }

    function test_rebalance_unlockCallback_onlyByPoolManager() public {
        // Adversarial: directly invoking unlockCallback on the rebalance
        // path is gated the same way as deposit/withdraw paths.
        bytes memory data = abi.encode(uint8(3), bytes(""));
        vm.expectRevert(DirectionalLiquidityHook.NotPoolManagerUnlock.selector);
        hook.unlockCallback(data);
    }

    function test_deposit_directModifyLiquidityIsBlocked() public {
        // Adversarial: a direct call to `manager.modifyLiquidity` for our
        // pool must trip `_beforeAddLiquidity` and revert. We invoke this
        // through a helper router-like path: the simplest is a direct
        // `unlock` from a 3rd-party caller that tries to add liquidity.
        DirectModifyAttacker attacker = new DirectModifyAttacker(manager, key);
        token0.mint(address(attacker), 1 ether);
        token1.mint(address(attacker), 1 ether);

        vm.expectRevert(); // wraps DirectLiquidityModificationDisabled
        attacker.attemptAdd(1e18);
    }

    function test_directRemoveLiquidityIsBlocked() public {
        // Adversarial: a direct call to `manager.modifyLiquidity` for a
        // remove must trip `_beforeRemoveLiquidity` and revert. Symmetric
        // to test_deposit_directModifyLiquidityIsBlocked but covering the
        // remove path so the line-coverage on `_beforeRemoveLiquidity` is
        // not just "callable from PoolManager-route" but also "blocks
        // external callers in flight."
        DirectModifyAttacker attacker = new DirectModifyAttacker(manager, key);
        vm.expectRevert(); // wraps DirectLiquidityModificationDisabled
        attacker.attemptRemove(1e18);
    }

    function test_unlockCallback_revertsOnUnknownAction() public {
        // The `revert UnknownAction()` branch is otherwise unreachable —
        // only PoolManager can call unlockCallback, and the hook's own
        // entry points only ever encode actions 1/2/3. Spoofed payload
        // covers the defensive path.
        bytes memory data = abi.encode(uint8(99), bytes(""));
        vm.prank(address(manager));
        vm.expectRevert(DirectionalLiquidityHook.UnknownAction.selector);
        hook.unlockCallback(data);
    }

    // ---------------------------------------------------------------- //
    // Spec §11 open-question coverage                                  //
    // ---------------------------------------------------------------- //

    function test_specQ11_4_continuationRebalanceProceedsWithZeroFees() public {
        // Spec §11.4: keeper calls `rebalance()` and a mode genuinely
        // needs to shift but no fees have accrued to its v4 position.
        // For Mode-Right / Mode-Left / Mode-Both continuation this is
        // the *common* case, not an edge: the mode position sits one
        // bin behind the active price, so a continuation move (price
        // travelling further away from the position) never crosses the
        // position's range and never charges a fee against it. The
        // rebalance must still proceed — the position needs to follow
        // the price, regardless of whether the keeper earns anything.

        vm.prank(alice);
        hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);

        // Drive a real swap upward (zeroForOne=false). Mode Right is at
        // [-60, 0); the swap starts at tick 0 and moves further up. The
        // position is *never* in the swap's path → zero fees.
        vm.warp(1_000);
        _seedTwapFromSlot0();
        vm.warp(1_500);
        _realSwapToTick(200, 1e15);
        (, int24 postSwapTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertGe(int256(postSwapTick), int256(60), "swap moved past trigger");

        // Pile observations so TWAP converges past the trigger threshold.
        _seedTwapAt(postSwapTick, 12, 60);

        // Snapshot accumulator + keeper balance before the rebalance.
        DirectionalLiquidityHook.ModeState memory before_ = hook.modeState(ModeRange.MODE_RIGHT);
        assertEq(before_.feePerShareCumulative0, 0, "no t0 fees pre-rebalance");
        assertEq(before_.feePerShareCumulative1, 0, "no t1 fees pre-rebalance");

        address keeper = makeAddr("zeroFeeKeeper");
        uint256 keeperT0Before = token0.balanceOf(keeper);
        uint256 keeperT1Before = token1.balanceOf(keeper);

        vm.prank(keeper);
        hook.rebalance(); // must NOT revert despite zero fees

        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_RIGHT);

        // Range shifted (the actual purpose of the rebalance).
        assertTrue(
            after_.currentRangeLower != before_.currentRangeLower
                || after_.currentRangeUpper != before_.currentRangeUpper,
            "range shifted"
        );
        // Accumulator unchanged — there were no fees to fold in.
        assertEq(after_.feePerShareCumulative0, before_.feePerShareCumulative0, "accum t0 unchanged");
        assertEq(after_.feePerShareCumulative1, before_.feePerShareCumulative1, "accum t1 unchanged");
        // Keeper got nothing — also expected, no fees to share from.
        assertEq(token0.balanceOf(keeper), keeperT0Before, "keeper t0 unchanged");
        assertEq(token1.balanceOf(keeper), keeperT1Before, "keeper t1 unchanged");
        // Total shares preserved.
        assertEq(uint256(after_.totalShares), uint256(before_.totalShares), "totalShares preserved");
    }

    function test_specQ11_2_firstDepositUsesSpotTickWithoutObservations() public {
        // Spec §11.2: first-deposit lazy init must succeed even when the
        // TWAP buffer is empty (no swaps have happened yet). The hook
        // falls back to the pool's spot tick rather than blocking
        // deposits until N observations land. Adversarial framing: a
        // depositor can deposit as the *very first* action against a
        // freshly-initialized pool and the range is determined by spot.

        // Re-init a fresh pool at a non-zero tick so the assertion isn't
        // trivially "tick 0 → range based on tick 0." Use a tick that
        // sits cleanly inside a bin so the active-bin geometry is
        // unambiguous.
        int24 spotTick = 1_020; // 17 * 60; bin [1020, 1080)
        // Re-init: the existing setUp() already initialized at tick 0,
        // so we deploy a fresh pool fixture inline.
        PoolManager freshManager = new PoolManager(address(this));
        // Mine a new hook address with the same flag bits and a unique
        // prefix so the deployed code doesn't collide with the main hook.
        address freshHookAddr = address(uint160(0x8888 << 144) | uint160(EXPECTED_FLAGS));
        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(freshHookAddr)
        });
        deployCodeTo(
            "DirectionalLiquidityHook.sol:DirectionalLiquidityHook",
            abi.encode(
                IPoolManager(address(freshManager)),
                freshKey,
                BIN_WIDTH,
                TWAP_WINDOW,
                KEEPER_REWARD_BPS,
                BUFFER_SIZE,
                NAME,
                SYMBOL
            ),
            freshHookAddr
        );
        DirectionalLiquidityHook freshHook = DirectionalLiquidityHook(payable(freshHookAddr));
        freshManager.initialize(freshKey, TickMath.getSqrtPriceAtTick(spotTick));

        // Confirm the buffer is empty and getTwap reverts.
        assertEq(uint256(freshHook.observationCount()), 0, "buffer empty pre-deposit");
        vm.expectRevert(DirectionalLiquidityHook.NoObservations.selector);
        freshHook.getTwap();

        // Approve the fresh hook from Alice.
        vm.startPrank(alice);
        token0.approve(address(freshHook), type(uint256).max);
        token1.approve(address(freshHook), type(uint256).max);
        // First deposit must succeed using spot tick — no TWAP available.
        uint256 tokenId = freshHook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);
        vm.stopPrank();

        // Mode Right at spotTick=1020 → activeBin = [1020, 1080) →
        // position one bin LEFT = [960, 1020).
        DirectionalLiquidityHook.ModeState memory ms = freshHook.modeState(ModeRange.MODE_RIGHT);
        assertEq(int256(ms.currentRangeLower), int256(960), "lazy init lower from spot");
        assertEq(int256(ms.currentRangeUpper), int256(1_020), "lazy init upper from spot");
        assertTrue(ms.initialized, "mode initialized on first deposit");
        assertEq(uint256(freshHook.ownerOf(tokenId) == alice ? 1 : 0), 1, "NFT owner is alice");
    }

    function test_rebalance_modeBothReversal_sameBinNoOpFlipsDirInPlace() public {
        // Spec §5.5 same-bin shortcut: when reversal triggers but the new
        // range geometry coincides with the current range, skip the
        // burn-and-remint and just flip `lastShiftDir`. Previously this
        // was buggy (the post-loop revert wiped the storage write); the
        // fix splits the unlock from the no-op revert. This test would
        // fail with `NothingToRebalance` if the bug were ever
        // reintroduced.
        vm.prank(alice);
        hook.deposit(ModeRange.MODE_BOTH, 1e18, alice);

        DirectionalLiquidityHook.ModeState memory init = hook.modeState(ModeRange.MODE_BOTH);
        assertEq(int256(init.currentRangeLower), int256(-60));
        assertEq(int256(init.currentRangeUpper), int256(0));
        assertFalse(init.lastShiftDir, "initial dir = false");

        // Drive TWAP to -65 (just past the position lower) via faked
        // observations. This is the canonical same-bin scenario: dir=true
        // at twap=-65 → activeBin=[-120, -60) → position [-60, 0) =
        // unchanged.
        _setSlot0Tick(-65);
        vm.warp(10_000);
        _callAfterSwap();
        vm.warp(10_000 + TWAP_WINDOW + 1);
        _callAfterSwap();
        assertLt(int256(hook.getTwap()), int256(-60), "twap past trigger");

        // Rebalance: must NOT revert; must flip dir; must leave range.
        hook.rebalance();

        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_BOTH);
        assertTrue(after_.lastShiftDir, "dir flipped true");
        assertEq(int256(after_.currentRangeLower), int256(-60), "range unchanged (same-bin)");
        assertEq(int256(after_.currentRangeUpper), int256(0), "range unchanged (same-bin)");
        assertEq(uint256(after_.totalShares), uint256(init.totalShares), "shares unchanged");
    }

    function test_twap_returnsNewestWhenWindowExceedsNow() public {
        // Coverage gap: `if (nowTs <= twapWindow) return newest.tick`.
        // Reachable by writing an observation while block.timestamp is
        // less than twapWindow (so target = now - window would underflow).
        vm.warp(uint256(TWAP_WINDOW) - 1); // now < twapWindow
        _setSlot0Tick(77);
        _callAfterSwap();
        assertEq(int256(hook.getTwap()), int256(77), "fallback to newest tick");
    }

    function test_twap_extrapolatesWhenTargetAfterNewest() public {
        // Coverage gap: `!hasAfter` branch — target lies at-or-after the
        // newest observation. Reachable when the newest observation is
        // older than `twapWindow` ago, so the walk doesn't find any
        // strictly-newer observation and `hasAfter` stays false.
        vm.warp(1_000);
        _setSlot0Tick(50);
        _callAfterSwap(); // o0: ts=1000, tick=50

        // Jump far past twapWindow. Now `target = now - window > o0.ts`,
        // so o0 is the at-or-before, after_ stays at o0, hasAfter=false.
        vm.warp(1_000 + uint256(TWAP_WINDOW) * 5);
        // Same target tick keeps the math obvious: TWAP must converge to 50.
        assertEq(int256(hook.getTwap()), int256(50), "extrapolation TWAP");
    }

    function test_views_externalReadHelpersAreReachable() public view {
        // Coverage gap: `binTicks()` and `rangeForMode()` external views
        // are exposed for off-chain integrators (LP UIs, keeper bots) but
        // weren't called from any test before. Smoke them so the surface
        // is covered.
        assertEq(int256(hook.binTicks()), int256(60), "binTicks = binWidth * tickSpacing");
        (int24 lower, int24 upper) = hook.rangeForMode(ModeRange.MODE_RIGHT, 0, false);
        assertEq(int256(lower), int256(-60));
        assertEq(int256(upper), int256(0));
        // Mode Both with dir=true should mirror to the right of the active bin.
        (int24 bothL, int24 bothU) = hook.rangeForMode(ModeRange.MODE_BOTH, 0, true);
        assertEq(int256(bothL), int256(60));
        assertEq(int256(bothU), int256(120));
    }

    // ---------------------------------------------------------------- //
    // Swap-driven fixture                                              //
    // ---------------------------------------------------------------- //
    //
    // Background: tests above use `vm.store` to move slot0's tick without
    // moving the underlying token reserves. That works for buffer mechanics
    // and for shifts where the post-burn currency happens to match what the
    // pool actually holds (Mode-Right / Mode-Left continuation), but it
    // breaks Mode-Both reversal: a faked tick implies the position should
    // have flipped sides token-wise, but its v4 state still holds the
    // original currency, so the burn returns the wrong side.
    //
    // The fixture below uses PoolSwapTest to drive real swaps. Each swap
    // fires `_afterSwap` (writing one TWAP observation) and updates slot0
    // honestly. Use `_realSwapToTick` to move the price to a target tick,
    // and `_seedTwapPastTick` to pile up enough observations that
    // `getTwap()` returns at-or-past a target value. Both helpers respect
    // `vm.warp`, so the caller controls observation spacing.
    //
    // Note on liquidity: the hook blocks all direct adds, so "baseline LP"
    // is itself a deposit-into-a-mode call. We use Mode-Both itself as the
    // liquidity scaffold for these tests — the swap consumes its tokens as
    // it moves through the position, then glides freely past it (zero-
    // liquidity travel) toward the trigger threshold.

    /// @dev Drive the pool's tick to (approximately) `targetTick` by swapping
    ///      against the price limit. Uses `amountIn` as the spend cap; the
    ///      swap stops at whichever bound trips first (limit or amountIn).
    ///      Also writes one TWAP observation as a side effect.
    function _realSwapToTick(int24 targetTick, uint256 amountIn) internal {
        (, int24 spotTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        bool zeroForOne = targetTick < spotTick;
        uint160 limit = TickMath.getSqrtPriceAtTick(targetTick);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: limit
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(swapper);
        swapRouter.swap(key, params, settings, bytes(""));
    }

    /// @dev Seed the TWAP buffer with `steps` observations spaced
    ///      `intervalSec` apart, each at `tick`. Uses `_setPoolPriceAtTick`
    ///      so slot0's sqrtPrice stays coherent with the tick — important
    ///      for swap-driven tests that may swap again afterward. After the
    ///      call, `block.timestamp` is at the last observation.
    function _seedTwapAt(int24 tick, uint16 steps, uint32 intervalSec) internal {
        for (uint16 i = 0; i < steps; i++) {
            vm.warp(block.timestamp + intervalSec);
            _setPoolPriceAtTick(tick);
            _callAfterSwap();
        }
    }

    /// @dev Initial observation at the pool's REAL slot0 (no vm.store).
    ///      Use this to seed the TWAP buffer before driving swaps so that
    ///      the price-limit math in subsequent swaps sees the true sqrt
    ///      price (vm.store-based tick seeding clobbers sqrtPriceX96 to 1
    ///      and breaks PoolManager.swap's limit check).
    function _seedTwapFromSlot0() internal {
        vm.prank(address(manager));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), bytes(""));
    }

    function test_swapDriven_modeRight_continuationRebalance() public {
        // Sanity: the existing vm.store-based continuation test exercises
        // the trigger logic; this one verifies the same shift happens
        // under a real swap. Setup: deposit Mode Right at tick 0, swap
        // to drive price upward past the trigger threshold.
        vm.prank(alice);
        hook.deposit(ModeRange.MODE_RIGHT, 1e18, alice);

        DirectionalLiquidityHook.ModeState memory before_ = hook.modeState(ModeRange.MODE_RIGHT);
        assertEq(int256(before_.currentRangeLower), int256(-60));

        // First, write an initial observation at the pool's real slot0
        // (currently tick 0, sqrtPrice 1<<96) so the buffer has a
        // baseline. We can't use _setSlot0Tick here because it clobbers
        // sqrtPriceX96 to 1, which would break the next swap's limit
        // check.
        vm.warp(1_000);
        _seedTwapFromSlot0();

        // Drive a real swap upward to tick 200. With no liquidity above
        // the active bin (Mode Right is below price), the swap glides
        // freely to the limit; one observation is written on the way.
        vm.warp(1_500);
        _realSwapToTick(200, 1e15);

        (, int24 postSwapTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertGe(int256(postSwapTick), int256(60), "real swap moved tick past trigger");

        // Pile up observations at the new tick so TWAP converges.
        _seedTwapAt(postSwapTick, 12, 60);

        // Capture the on-chain TWAP before calling rebalance — guards
        // against silent regressions in TWAP wiring.
        int24 twap = hook.getTwap();
        assertGe(int256(twap), int256(60), "TWAP cleared rebalance trigger");

        hook.rebalance();

        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_RIGHT);
        // New range = one bin behind the active bin at TWAP. With binTicks=60
        // and twap >= 60, the active bin sits at [twapBinFloor, +binTicks)
        // and Mode Right's new range is one bin to its left.
        int24 binF = (twap / 60) * 60;
        if (twap < 0 && twap % 60 != 0) binF -= 60;
        assertEq(int256(after_.currentRangeUpper), int256(binF), "shift placed upper at active-bin lower");
        assertEq(int256(after_.currentRangeLower), int256(binF - 60), "shift placed lower one bin below");
        assertEq(uint256(after_.totalShares), uint256(before_.totalShares), "totalShares unchanged");
        assertTrue(after_.initialized, "still initialized");
    }

    function test_swapDriven_modeBoth_reversalEndToEnd() public {
        // The defining Mode-Both test: deposit, drive price through the
        // position and out the other side via real swaps, rebalance, and
        // verify the dir flipped and the new range is on the new side.
        vm.prank(alice);
        hook.deposit(ModeRange.MODE_BOTH, 100e18, alice); // chunky liq → swappable

        DirectionalLiquidityHook.ModeState memory init = hook.modeState(ModeRange.MODE_BOTH);
        assertEq(int256(init.currentRangeLower), int256(-60));
        assertEq(int256(init.currentRangeUpper), int256(0));
        assertFalse(init.lastShiftDir, "init dir = false (position left of price)");

        // Seed a baseline observation at the pool's real tick 0.
        vm.warp(1_000);
        _seedTwapFromSlot0();

        // Drive price down past the position's lower (-60) via a real swap.
        // The swap consumes Mode Both's currency1 reserves as it crosses
        // into the position, converting them to currency0. Past -60, it
        // glides freely (no liquidity) until the price-limit at -300.
        vm.warp(1_500);
        _realSwapToTick(-300, 200e18);

        (, int24 postSwapTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLt(int256(postSwapTick), int256(-60), "real swap moved tick past position lower");

        // Pile up observations so TWAP converges below -60 (the reversal
        // threshold for dir=false: twap < rangeLower).
        _seedTwapAt(postSwapTick, 12, 60);
        int24 twap = hook.getTwap();
        assertLt(int256(twap), int256(-60), "TWAP crossed reversal threshold");

        // Rebalance. Reversal must flip lastShiftDir to true, and the new
        // range must sit ABOVE the new active bin (dir=true geometry).
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        hook.rebalance();

        DirectionalLiquidityHook.ModeState memory after_ = hook.modeState(ModeRange.MODE_BOTH);
        assertTrue(after_.lastShiftDir, "reversal flipped dir");

        // Compute the expected new range: dir=true → position one bin to
        // the RIGHT of the active bin at TWAP.
        int24 binF = (twap / 60) * 60;
        if (twap < 0 && twap % 60 != 0) binF -= 60;
        int24 activeUpper = binF + 60;
        assertEq(int256(after_.currentRangeLower), int256(activeUpper), "reversal: lower at active upper");
        assertEq(int256(after_.currentRangeUpper), int256(activeUpper + 60), "reversal: upper one bin further");

        assertTrue(after_.initialized, "still initialized");
        assertEq(uint256(after_.totalShares), uint256(init.totalShares), "totalShares unchanged");
    }

    function test_getHookPermissions_onlyExpectedFlagsSet() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeAddLiquidity, "beforeAddLiquidity should be enabled");
        assertTrue(p.beforeRemoveLiquidity, "beforeRemoveLiquidity should be enabled");
        assertTrue(p.afterSwap, "afterSwap should be enabled");

        // All others must be false — never enable a permission we don't use.
        assertFalse(p.beforeInitialize, "beforeInitialize should be disabled");
        assertFalse(p.afterInitialize, "afterInitialize should be disabled");
        assertFalse(p.afterAddLiquidity, "afterAddLiquidity should be disabled");
        assertFalse(p.afterRemoveLiquidity, "afterRemoveLiquidity should be disabled");
        assertFalse(p.beforeSwap, "beforeSwap should be disabled");
        assertFalse(p.beforeDonate, "beforeDonate should be disabled");
        assertFalse(p.afterDonate, "afterDonate should be disabled");
        assertFalse(p.beforeSwapReturnDelta, "beforeSwapReturnDelta should be disabled");
        assertFalse(p.afterSwapReturnDelta, "afterSwapReturnDelta should be disabled");
        assertFalse(p.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be disabled");
        assertFalse(p.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be disabled");
    }
}

/// @dev Tries to add liquidity directly to the pool (bypassing the hook's
///      `deposit` flow). The `_beforeAddLiquidity` callback should revert
///      this with `DirectLiquidityModificationDisabled`.
contract DirectModifyAttacker {
    IPoolManager immutable manager;
    PoolKey internal _key;

    constructor(IPoolManager _manager, PoolKey memory k) {
        manager = _manager;
        _key = k;
    }

    function attemptAdd(uint128 liquidity) external {
        manager.unlock(abi.encode(uint8(0), liquidity));
    }

    /// @dev Mirror of `attemptAdd` but routes through `_beforeRemoveLiquidity`.
    function attemptRemove(uint128 liquidity) external {
        manager.unlock(abi.encode(uint8(1), liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (uint8 op, uint128 liq) = abi.decode(data, (uint8, uint128));
        // op=0 = add (positive delta), op=1 = remove (negative delta).
        // Either path bypasses the hook's `deposit`/`withdraw` wrappers
        // and is supposed to be blocked by `_beforeAddLiquidity` /
        // `_beforeRemoveLiquidity` when the caller is not the hook itself.
        int256 delta = op == 0 ? int256(uint256(liq)) : -int256(uint256(liq));
        manager.modifyLiquidity(
            _key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 0, liquidityDelta: delta, salt: bytes32(0)}),
            bytes("")
        );
        return bytes("");
    }
}
