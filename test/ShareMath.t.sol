// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShareMath} from "../src/libraries/ShareMath.sol";

/// @dev Thin wrapper so `vm.expectRevert` sees a real external call frame.
///      Library calls are inlined into the test contract otherwise.
contract ShareMathWrapper {
    function sharesForDeposit(uint128 a, uint128 b, uint128 c) external pure returns (uint128) {
        return ShareMath.sharesForDeposit(a, b, c);
    }

    function liquidityForWithdraw(uint128 a, uint128 b, uint128 c) external pure returns (uint128) {
        return ShareMath.liquidityForWithdraw(a, b, c);
    }

    function pendingFees(uint128 s, uint256 cur, uint256 snap) external pure returns (uint256) {
        return ShareMath.pendingFees(s, cur, snap);
    }
}

/// @title ShareMathTest
/// @notice Pure-function tests for the share + fee-accumulator math used by
///         `DirectionalLiquidityHook`. No v4 dependencies.
contract ShareMathTest is Test {
    ShareMathWrapper internal w;

    function setUp() public {
        w = new ShareMathWrapper();
    }

    // ------------------------------------------------------------------ //
    // sharesForDeposit                                                   //
    // ------------------------------------------------------------------ //

    function test_shares_proRataMatchesLiquidity() public pure {
        // Doubling the mode's liquidity at parity → caller gets totalShares.
        uint128 issued = ShareMath.sharesForDeposit({
            depositLiquidity: 1_000,
            totalShares: 1_000,
            modeLiquidity: 1_000
        });
        assertEq(uint256(issued), 1_000);
    }

    function test_shares_dilutionWhenSharesAlreadyDiluted() public pure {
        // Pre-existing 2:1 dilution (totalShares=2000 backing 1000 liq).
        // A 1000-liq deposit should mint 2000 shares to preserve ratio.
        uint128 issued = ShareMath.sharesForDeposit({
            depositLiquidity: 1_000,
            totalShares: 2_000,
            modeLiquidity: 1_000
        });
        assertEq(uint256(issued), 2_000);
    }

    function test_shares_revertsOnUninitialized() public {
        vm.expectRevert(bytes("ShareMath: not initialized"));
        w.sharesForDeposit(100, 0, 100);

        vm.expectRevert(bytes("ShareMath: not initialized"));
        w.sharesForDeposit(100, 100, 0);
    }

    function testFuzz_shares_roundTripWithdraw(uint128 totalShares, uint128 modeLiq, uint128 dep) public pure {
        // Bound to uint64 so dep × totalShares can't overflow uint128 even
        // before the FullMath divide.
        totalShares = uint128(bound(uint256(totalShares), 1, type(uint64).max));
        modeLiq = uint128(bound(uint256(modeLiq), 1, type(uint64).max));
        dep = uint128(bound(uint256(dep), 1, type(uint64).max));

        uint128 issued = ShareMath.sharesForDeposit(dep, totalShares, modeLiq);

        uint128 newTotal = totalShares + issued;
        uint128 newLiq = modeLiq + dep;
        uint128 out = ShareMath.liquidityForWithdraw(issued, newTotal, newLiq);
        // Burn returns ≤ dep. The two divisions floor each direction, so
        // strict equality doesn't hold; bound the loss tightly.
        assertLe(uint256(out), uint256(dep), "round-trip must not pay out more than deposited");
    }

    // ------------------------------------------------------------------ //
    // liquidityForWithdraw                                               //
    // ------------------------------------------------------------------ //

    function test_withdraw_burnsProRata() public pure {
        // 25% of the shares → 25% of the liquidity.
        uint128 out = ShareMath.liquidityForWithdraw({
            shares: 250,
            totalShares: 1_000,
            modeLiquidity: 4_000
        });
        assertEq(uint256(out), 1_000);
    }

    function test_withdraw_revertsWhenSharesExceedTotal() public {
        vm.expectRevert(bytes("ShareMath: shares > total"));
        w.liquidityForWithdraw(1_001, 1_000, 1_000);
    }

    function test_withdraw_emptyModeReverts() public {
        vm.expectRevert(bytes("ShareMath: empty mode"));
        w.liquidityForWithdraw(0, 0, 0);
    }

    // ------------------------------------------------------------------ //
    // accrueFeePerShare + pendingFees                                    //
    // ------------------------------------------------------------------ //

    function test_accrue_noopWhenNoShares() public pure {
        uint256 prev = 12345;
        uint256 next = ShareMath.accrueFeePerShare(prev, 1_000, 0);
        assertEq(next, prev, "accumulator must not move when totalShares=0");
    }

    function test_accrue_noopWhenNoFees() public pure {
        assertEq(ShareMath.accrueFeePerShare(7, 0, 100), 7);
    }

    function test_pending_zeroSharesReturnsZero() public pure {
        assertEq(ShareMath.pendingFees(0, 1_000_000, 0), 0);
    }

    function test_pending_revertsWhenSnapshotAhead() public {
        vm.expectRevert(bytes("ShareMath: snapshot > current"));
        w.pendingFees(1, 100, 200);
    }

    /// Round-trip: split 1e18 fees across 3 LPs proportionally. Sum of
    /// payouts must match the input within rounding error (≤ N wei for N
    /// LPs — each pendingFees does one Q128-floor division).
    function test_accrue_pendingRoundTrip() public pure {
        uint128 sharesA = 100;
        uint128 sharesB = 200;
        uint128 sharesC = 300;
        uint128 total = sharesA + sharesB + sharesC; // 600
        uint256 fees = 1e18;

        uint256 cum = ShareMath.accrueFeePerShare(0, fees, total);

        uint256 owedA = ShareMath.pendingFees(sharesA, cum, 0);
        uint256 owedB = ShareMath.pendingFees(sharesB, cum, 0);
        uint256 owedC = ShareMath.pendingFees(sharesC, cum, 0);

        uint256 sum = owedA + owedB + owedC;
        assertLe(sum, fees, "must not pay out more than collected");
        // Per-LP floor loses at most 1 wei × number of LPs.
        assertGe(sum, fees - 3, "round-trip drops at most N wei for N LPs");
    }

    /// LPs who joined later (with a non-zero snapshot) only earn the
    /// post-snapshot increment.
    function test_pending_respectsSnapshot() public pure {
        uint128 totalShares = 1_000;
        uint256 cum0 = 0;
        uint256 cum1 = ShareMath.accrueFeePerShare(cum0, 500, totalShares);
        uint256 cum2 = ShareMath.accrueFeePerShare(cum1, 500, totalShares);

        // LP joined after the first 500 fees were accrued → snapshot = cum1.
        // They should earn only the 500 from the second leg.
        uint128 lpShares = 100; // 10% of total
        uint256 owed = ShareMath.pendingFees(lpShares, cum2, cum1);
        assertEq(owed, 50, "should earn 10% of the 500 accrued post-join");
    }

    /// Late-joining LP must not be able to claim pre-deposit fees — the JIT
    /// attack surface noted in spec §7.3.
    function test_pending_lateJoinerCannotClaimPreFees() public pure {
        uint128 totalShares = 1_000;
        uint256 cum1 = ShareMath.accrueFeePerShare(0, 1e18, totalShares);

        // LP deposits after fees accrued; their snapshot = cum1.
        uint256 owed = ShareMath.pendingFees(500, cum1, cum1);
        assertEq(owed, 0, "snapshot at deposit time must zero out past fees");
    }
}
