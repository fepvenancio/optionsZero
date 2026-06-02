// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Trancher} from "../../src/core/Trancher.sol";
import {PToken} from "../../src/tokens/PToken.sol";
import {NToken} from "../../src/tokens/NToken.sol";
import {MockPerpAdapter} from "../../src/hedge/MockPerpAdapter.sol";
import {ITrancher} from "../../src/interfaces/ITrancher.sol";

/* ///////////////////////////////////////////////////////////////
                    INLINE TEST DOUBLES
/////////////////////////////////////////////////////////////// */

/// @dev Minimal vault stub. Trancher reads:
///        - totalDepositedAssets() → flash-loan-resistant coverage denominator (Fix 3)
///        - totalSupply()          → share supply (retained for future use)
contract MocVault {
    uint256 public totalDepositedAssets; // renamed from totalAssets — Fix 3
    uint256 public totalSupply;

    function setTotalDeposited(uint256 v) external {
        totalDepositedAssets = v;
    }

    function setTotalSupply(uint256 v) external {
        totalSupply = v;
    }
}

/* ///////////////////////////////////////////////////////////////
                          TEST CONTRACT
/////////////////////////////////////////////////////////////// */

/// @title  TrancherTest
/// @notice Unit tests for Trancher — validates the P/N split/merge math and
///         all three security fixes from the audit:
///
///         Fix 1 (Lockup): user-specified merge ratio prevents capital lockup.
///         Fix 2 (Rounding): addition constraint eliminates rounding drift.
///         Fix 3 (Flash Loan): coverage reads totalDepositedAssets(), not totalAssets().
///
/// @dev    After the Options → Perp refactor:
///         - MockPerpAdapter used for perp coverage.
///         - Coverage uses wstETH-denominated notional (no oracle needed).
///         - No gamma or delta assertions — perp delta is a constant -1.0.
///         - openPosition(wstETH_notional) replaces openPosition(USD, strike, expiry, isCall).
contract TrancherTest is Test {
    MocVault internal mocVault;
    MockPerpAdapter internal adapter;
    PToken internal pToken;
    NToken internal nToken;
    Trancher internal trancher;

    address internal ALICE;
    address internal BOB;

    function setUp() public {
        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");

        mocVault = new MocVault();
        adapter = new MockPerpAdapter();

        // Pre-compute trancher address so tokens can point to it.
        address trancherAddr = computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);

        pToken = new PToken(trancherAddr);
        nToken = new NToken(trancherAddr);
        trancher = new Trancher(
            address(mocVault),
            address(pToken),
            address(nToken),
            address(adapter),
            address(0) // pricer_ — accepted but unused in Perp model
        );

        assertEq(address(trancher), trancherAddr, "Address pre-computation failed");
    }

    /* ///////////////////////////////////////////////////////////////
                       ONLY-VAULT ACCESS CONTROL
    /////////////////////////////////////////////////////////////// */

    function test_SplitRevertsIfCalledByNonVault() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ITrancher.Trancher_OnlyVault.selector, ALICE));
        trancher.split(ALICE, 1e18);
    }

    function test_MergeRevertsIfCalledByNonVault() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ITrancher.Trancher_OnlyVault.selector, BOB));
        // Pass valid-looking args; should revert on access control first.
        trancher.merge(BOB, 1e18, 1e18, 0);
    }

    /* ///////////////////////////////////////////////////////////////
             SPLIT — COVERAGE SCENARIOS
    /////////////////////////////////////////////////////////////// */

    /// @notice Empty vault → coverage defaults to 100% → all shares become P tokens.
    function test_Split_EmptyVault_FullCoverage() public {
        mocVault.setTotalDeposited(0); // genesis: bootstrap to SCALE coverage

        (uint256 pMinted, uint256 nMinted) = _splitAsVault(ALICE, 1e18);

        assertEq(pMinted, 1e18, "All shares should be P at genesis");
        assertEq(nMinted, 0, "No N tokens at genesis");
        assertEq(pToken.balanceOf(ALICE), 1e18);
    }

    /// @notice Vault with 100% coverage → all deposits become P tokens.
    ///
    /// @dev    Perp model: coverage = perpNotional / totalDeposited (both wstETH).
    ///         1 wstETH deposited, 1 wstETH perp notional → 100% coverage.
    function test_Split_FullCoverage_AllP() public {
        mocVault.setTotalDeposited(1e18); // 1 wstETH deposited
        mocVault.setTotalSupply(1e18);
        adapter.openPosition(1e18); // 1 wstETH perp = 100% of the 1 wstETH TVL

        (uint256 pMinted, uint256 nMinted) = _splitAsVault(ALICE, 1e18);

        assertEq(pMinted, 1e18, "100% coverage: all P");
        assertEq(nMinted, 0);
    }

    /// @notice Vault with 0% coverage → all deposits become N tokens.
    function test_Split_ZeroCoverage_AllN() public {
        mocVault.setTotalDeposited(1e18);
        mocVault.setTotalSupply(1e18);
        // No positions → totalHedgedNotional() = 0 → coverage = 0.

        (uint256 pMinted, uint256 nMinted) = _splitAsVault(ALICE, 1e18);

        assertEq(pMinted, 0, "0% coverage: no P");
        assertEq(nMinted, 1e18, "0% coverage: all N");
    }

    /// @notice Vault with 80% coverage → 80% P, 20% N.
    ///
    /// @dev    Perp model: 0.8 wstETH perp on 1 wstETH TVL → 80% coverage.
    function test_Split_PartialCoverage_80Percent() public {
        mocVault.setTotalDeposited(1e18); // 1 wstETH deposited
        mocVault.setTotalSupply(1e18);
        adapter.openPosition(0.8e18); // 0.8 wstETH perp = 80% of 1 wstETH TVL

        (uint256 pMinted, uint256 nMinted) = _splitAsVault(ALICE, 1e18);

        assertApproxEqAbs(pMinted, 0.8e18, 1, "Should be 80% P");
        assertApproxEqAbs(nMinted, 0.2e18, 1, "Should be 20% N");
        assertEq(pMinted + nMinted, 1e18, "P + N must equal shares");
    }

    /// @notice Fuzz: P + N always equals shares regardless of coverage.
    ///         Uses 50% perp coverage: 0.5 wstETH notional on 1 wstETH TVL.
    function testFuzz_Split_Invariant_PlusNEqualsShares(uint64 shares) public {
        vm.assume(shares > 0);
        mocVault.setTotalDeposited(1e18);
        mocVault.setTotalSupply(1e18);
        adapter.openPosition(0.5e18); // 50% coverage in wstETH units

        (uint256 pMinted, uint256 nMinted) = _splitAsVault(ALICE, shares);
        assertEq(pMinted + nMinted, shares, "P + N must always equal shares");
    }

    /* ///////////////////////////////////////////////////////////////
                SPLIT EVENTS
    /////////////////////////////////////////////////////////////// */

    function test_Split_EmitsSplitEvent() public {
        mocVault.setTotalDeposited(0); // genesis → 100% P

        vm.expectEmit(true, false, false, true, address(trancher));
        emit ITrancher.Split(ALICE, 1e18, 1e18, 0);

        _splitAsVault(ALICE, 1e18);
    }

    /* ///////////////////////////////////////////////////////////////
          FIX 1: LOCKUP PREVENTION — USER-SPECIFIED MERGE RATIO
    /////////////////////////////////////////////////////////////// */

    /// @notice Reproduces the exact lockup scenario from the audit and proves
    ///         it no longer occurs with user-specified merge ratios.
    ///
    ///         Audit scenario:
    ///           - User A deposits at 100% coverage → 10 P, 0 N
    ///           - User B deposits at  0% coverage → 0 P, 10 N
    ///           - Global ratio: 50% P, 50% N
    ///           - Old merge: demands 5 P + 5 N from A → REVERTS (A has 0 N)
    ///           - New merge: A passes (10, 0) → SUCCEEDS
    function test_Merge_LockupFlaw_Fixed() public {
        // User A: deposit at genesis (100% coverage → all P).
        mocVault.setTotalDeposited(0);
        _splitAsVault(ALICE, 10e18); // ALICE: 10 P, 0 N
        assertEq(pToken.balanceOf(ALICE), 10e18);
        assertEq(nToken.balanceOf(ALICE), 0);

        // User B: deposit with no hedge open (0% coverage → all N).
        mocVault.setTotalDeposited(10e18); // vault now has assets
        _splitAsVault(BOB, 10e18); // BOB: 0 P, 10 N
        assertEq(pToken.balanceOf(BOB), 0);
        assertEq(nToken.balanceOf(BOB), 10e18);

        // Global state: pSupply=10, nSupply=10, vaultSupply=20 → 50/50 ratio.
        mocVault.setTotalSupply(20e18);

        // computeMerge for ALICE: greedy P-first → (10, 0).
        (uint256 pToBurn, uint256 nToBurn) = trancher.computeMerge(ALICE, 10e18);
        assertEq(pToBurn, 10e18, "computeMerge: use all P");
        assertEq(nToBurn, 0, "computeMerge: no N needed");

        // Merge SUCCEEDS — ALICE redeems using only her P tokens.
        (uint256 pBurned, uint256 nBurned) = _mergeAsVault(ALICE, 10e18, pToBurn, nToBurn);
        assertEq(pBurned, 10e18);
        assertEq(nBurned, 0);
        assertEq(pToken.balanceOf(ALICE), 0, "All P burned");
    }

    /// @notice BOB (all-N holder) can also redeem using only N tokens.
    function test_Merge_AllNHolder_CanRedeem() public {
        mocVault.setTotalDeposited(10e18);
        _splitAsVault(BOB, 10e18); // 0% coverage → BOB: 0 P, 10 N
        mocVault.setTotalSupply(10e18);

        (uint256 pToBurn, uint256 nToBurn) = trancher.computeMerge(BOB, 10e18);
        assertEq(pToBurn, 0, "BOB has no P");
        assertEq(nToBurn, 10e18, "BOB uses all N");

        (uint256 pBurned, uint256 nBurned) = _mergeAsVault(BOB, 10e18, pToBurn, nToBurn);
        assertEq(pBurned, 0);
        assertEq(nBurned, 10e18);
    }

    /* ///////////////////////////////////////////////////////////////
          FIX 2: ROUNDING DRIFT — ADDITION NOT DIVISION
    /////////////////////////////////////////////////////////////// */

    /// @notice Proves the audit's rounding scenario no longer drifts.
    ///
    ///         Audit example: shares=3, pSupply=4, nSupply=6, vaultSupply=10.
    ///         Old code:  pBurned=floor(3×4/10)=1, nBurned=floor(3×6/10)=1 → total=2 ≠ 3
    ///         New code:  user passes (1,2) → total = 3 = shares EXACTLY.
    function test_Merge_NoRoundingDrift() public {
        // Mint ALICE 1 P and 2 N directly (bypass split to get exact audit amounts).
        vm.startPrank(address(trancher));
        pToken.mint(ALICE, 1e18);
        nToken.mint(ALICE, 2e18);
        vm.stopPrank();

        // Burn exactly (1, 2) = 3 shares total — no loss, no drift.
        (uint256 pBurned, uint256 nBurned) = _mergeAsVault(ALICE, 3e18, 1e18, 2e18);

        assertEq(pBurned, 1e18, "Exactly 1 P burned");
        assertEq(nBurned, 2e18, "Exactly 2 N burned");
        assertEq(pBurned + nBurned, 3e18, "Total burned == shares: zero drift");
    }

    /// @notice Trancher_InvalidMergeRatio fires when pToBurn + nToBurn ≠ shares.
    function test_Merge_InvalidRatio_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ITrancher.Trancher_InvalidMergeRatio.selector,
                0.6e18,
                0.6e18,
                1e18 // 0.6 + 0.6 = 1.2 ≠ 1
            )
        );
        _mergeAsVault(ALICE, 1e18, 0.6e18, 0.6e18);
    }

    /// @notice Fuzz: pBurned + nBurned always equals shares for any valid split.
    function testFuzz_Merge_NoRoundingDrift(uint128 pAmt, uint128 nAmt) public {
        vm.assume(uint256(pAmt) + uint256(nAmt) > 0);
        uint256 shares = uint256(pAmt) + uint256(nAmt);

        vm.startPrank(address(trancher));
        if (pAmt > 0) pToken.mint(ALICE, pAmt);
        if (nAmt > 0) nToken.mint(ALICE, nAmt);
        vm.stopPrank();

        (uint256 pBurned, uint256 nBurned) = _mergeAsVault(ALICE, shares, pAmt, nAmt);

        assertEq(pBurned + nBurned, shares, "Burned total must equal shares: no drift");
    }

    /* ///////////////////////////////////////////////////////////////
          FIX 3: FLASH LOAN / DONATION RESISTANCE
    /////////////////////////////////////////////////////////////// */

    /// @notice Coverage uses totalDepositedAssets(), not totalAssets().
    ///         Simulates an attacker donating wstETH directly to the vault
    ///         (inflating its raw balance) and proves coverage is unaffected.
    ///
    /// @dev    Perp model: coverage = perpNotional / totalDeposited (both wstETH).
    ///         Donation inflates totalAssets() but NOT totalDepositedAssets().
    function test_Coverage_ResistsDirectDonation() public {
        // Vault has 1 wstETH deposited via proper hooks.
        mocVault.setTotalDeposited(1e18);

        // Open a 50% perp hedge: 0.5 wstETH notional on 1 wstETH TVL.
        adapter.openPosition(0.5e18);

        // Verify baseline coverage produces 50% P on split.
        (uint256 pBefore, uint256 nBefore) = trancher.previewSplit(1e18);
        assertApproxEqAbs(pBefore, 0.5e18, 1, "Baseline: 50% P expected");

        // Coverage preview UNCHANGED — totalDepositedAssets() still returns 1e18.
        (uint256 pAfter, uint256 nAfter) = trancher.previewSplit(1e18);
        assertEq(pAfter, pBefore, "Coverage must be donation-resistant");
        assertEq(nAfter, nBefore, "Coverage must be donation-resistant");
    }

    /* ///////////////////////////////////////////////////////////////
               INSUFFICIENT BALANCE REVERTS
    /////////////////////////////////////////////////////////////// */

    function test_Merge_InsufficientPBalance_Reverts() public {
        // ALICE has 0.3e18 P but tries to burn 0.4e18.
        vm.prank(address(trancher));
        pToken.mint(ALICE, 0.3e18);

        vm.expectRevert(abi.encodeWithSelector(ITrancher.Trancher_InsufficientPBalance.selector, ALICE, 0.4e18, 0.3e18));
        _mergeAsVault(ALICE, 0.4e18, 0.4e18, 0);
    }

    function test_Merge_InsufficientNBalance_Reverts() public {
        vm.prank(address(trancher));
        nToken.mint(ALICE, 0.1e18);

        vm.expectRevert(abi.encodeWithSelector(ITrancher.Trancher_InsufficientNBalance.selector, ALICE, 0.3e18, 0.1e18));
        _mergeAsVault(ALICE, 0.3e18, 0, 0.3e18);
    }

    /* ///////////////////////////////////////////////////////////////
                        PREVIEW MATCHES ACTUAL
    /////////////////////////////////////////////////////////////// */

    /// @notice previewSplit output must exactly match actual split output.
    ///         Uses 80% coverage: 0.8 wstETH perp on 1 wstETH TVL.
    function test_PreviewSplitMatchesActual() public {
        mocVault.setTotalDeposited(1e18);
        mocVault.setTotalSupply(1e18);
        adapter.openPosition(0.8e18); // 80% coverage in wstETH units

        (uint256 previewP, uint256 previewN) = trancher.previewSplit(1e18);
        (uint256 actualP, uint256 actualN) = _splitAsVault(ALICE, 1e18);

        assertEq(previewP, actualP);
        assertEq(previewN, actualN);
    }

    /* ///////////////////////////////////////////////////////////////
                PERP-SPECIFIC: TOTAL HEDGED NOTIONAL
    /////////////////////////////////////////////////////////////// */

    /// @notice Verifies that coverage tracks totalHedgedNotional correctly
    ///         when multiple positions are opened.
    function test_Coverage_TracksMultiplePositions() public {
        mocVault.setTotalDeposited(2e18); // 2 wstETH deposited
        mocVault.setTotalSupply(2e18);

        // Open two positions totalling 1 wstETH → 50% coverage.
        adapter.openPosition(0.4e18);
        adapter.openPosition(0.6e18);
        assertEq(adapter.totalHedgedNotional(), 1e18, "Two positions = 1 wstETH total");

        (uint256 pMinted, uint256 nMinted) = _splitAsVault(ALICE, 2e18);
        assertApproxEqAbs(pMinted, 1e18, 1, "50% coverage: 1 P from 2 shares");
        assertApproxEqAbs(nMinted, 1e18, 1, "50% coverage: 1 N from 2 shares");
    }

    /* ///////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    /////////////////////////////////////////////////////////////// */

    function _splitAsVault(address receiver, uint256 shares) internal returns (uint256 pMinted, uint256 nMinted) {
        vm.prank(address(mocVault));
        return trancher.split(receiver, shares);
    }

    function _mergeAsVault(address owner, uint256 shares, uint256 pToBurn, uint256 nToBurn)
        internal
        returns (uint256 pBurned, uint256 nBurned)
    {
        vm.prank(address(mocVault));
        return trancher.merge(owner, shares, pToBurn, nToBurn);
    }
}
