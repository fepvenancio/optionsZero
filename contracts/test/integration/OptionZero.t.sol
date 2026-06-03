// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {Vault} from "../../src/core/Vault.sol";
import {Trancher} from "../../src/core/Trancher.sol";
import {PToken} from "../../src/tokens/PToken.sol";
import {NToken} from "../../src/tokens/NToken.sol";
import {MockPerpAdapter} from "../../src/hedge/MockPerpAdapter.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {BatchTypes} from "../../src/core/BatchTypes.sol";

/* ///////////////////////////////////////////////////////////////
                       MOCK DEPENDENCIES
/////////////////////////////////////////////////////////////// */

/// @dev Minimal ERC-20 representing wstETH — mint freely in tests.
contract MockWstETH is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped stETH";
    }

    function symbol() public pure override returns (string memory) {
        return "wstETH";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal pricer: fixed $3,000/wstETH oracle (for YieldAccumulator compat).
contract MockOptionsPricer {
    uint256 public constant USD_PER_WSTETH = 3_000e18;

    function getEthUsdPrice() external pure returns (uint256) {
        return 3_000e8;
    }

    function getWstETHRate() external pure returns (uint256) {
        return 1e18;
    }

    function wstETHToUSD(uint256 wstETHAmount) external pure returns (uint256) {
        return (wstETHAmount * USD_PER_WSTETH) / 1e18;
    }
}

/* ///////////////////////////////////////////////////////////////
             OptionZero Full Integration Suite (Perp Model)
/////////////////////////////////////////////////////////////// */

/// @title  OptionZeroIntegrationTest
/// @notice End-to-end integration test suite for the OptionZero Perp model.
///
///         Each test deploys a complete protocol environment in setUp() and
///         exercises a specific invariant under the 1x-short-ETH-perp hedge.
///
///         Deployment wiring:
///           MockWstETH          — underlying asset (no rebase)
///           MockOptionsPricer   — fixed $3,000/wstETH oracle
///           MockPerpAdapter     — configurable perp simulator (no gamma)
///           PToken(trancher_addr)
///           NToken(trancher_addr)
///           Trancher(vault_addr, pToken, nToken, perpAdapter, pricer)
///           Vault(wstETH, trancher, perpAdapter)
///
///         Addresses are deterministically pre-computed via vm.computeCreateAddress
///         to satisfy circular constructor dependencies (trancher ↔ vault).
contract OptionZeroIntegrationTest is Test {
    /* ///////////////////////////////////////////////////////////////
                          DEPLOYED CONTRACTS
    /////////////////////////////////////////////////////////////// */

    MockWstETH internal wstETH;
    MockOptionsPricer internal pricer;
    MockPerpAdapter internal adapter;
    PToken internal pToken;
    NToken internal nToken;
    Trancher internal trancher;
    Vault internal vault;

    /* ///////////////////////////////////////////////////////////////
                          TEST ACCOUNTS
    /////////////////////////////////////////////////////////////// */

    address internal ALICE;
    address internal BOB;
    address internal SETTLER;

    /* ///////////////////////////////////////////////////////////////
                             CONSTANTS
    /////////////////////////////////////////////////////////////// */

    /// @dev IMBALANCE_THRESHOLD_BPS from Vault: 1% of TVL triggers a resize intent.
    uint256 internal constant IMBALANCE_THRESHOLD_BPS = 100; // 1%

    /// @dev keccak256 topic for the IntentRequested(int256 indexed, uint256) event.
    bytes32 internal constant INTENT_TOPIC = keccak256("IntentRequested(int256,uint256)");

    /* ///////////////////////////////////////////////////////////////
                               SET UP
    /////////////////////////////////////////////////////////////// */

    /// @notice Deploy a full OptionZero environment and wire all dependencies.
    function setUp() public {
        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");
        SETTLER = makeAddr("settler");

        // Infrastructure: no inter-contract dependencies.
        wstETH = new MockWstETH();
        pricer = new MockOptionsPricer();
        adapter = new MockPerpAdapter();

        // Pre-compute deployment addresses using current nonce sequence.
        // Deploy order: pToken(+0) → nToken(+1) → trancher(+2) → vault(+3).
        uint64 nonce = vm.getNonce(address(this));
        address ptAddr = vm.computeCreateAddress(address(this), nonce);
        address ntAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address trAddr = vm.computeCreateAddress(address(this), nonce + 2);
        address vaAddr = vm.computeCreateAddress(address(this), nonce + 3);

        // Deploy in exact nonce order — any deviation breaks the pre-computation.
        pToken = new PToken(trAddr); // nonce + 0
        nToken = new NToken(trAddr); // nonce + 1
        trancher = new Trancher(
            vaAddr,
            ptAddr,
            ntAddr, // nonce + 2
            address(adapter),
            address(pricer)
        );
        vault = new Vault(address(wstETH), trAddr, address(adapter)); // nonce + 3
        vault.setWhitelistEnabled(false); // Disable whitelist for tests

        // Verify wiring is correct before any test runs.
        assertEq(address(pToken), ptAddr, "setUp: pToken address mismatch");
        assertEq(address(nToken), ntAddr, "setUp: nToken address mismatch");
        assertEq(address(trancher), trAddr, "setUp: trancher address mismatch");
        assertEq(address(vault), vaAddr, "setUp: vault address mismatch");

        wstETH.mint(ALICE, 100e18);
        wstETH.mint(BOB, 100e18);
        wstETH.mint(SETTLER, 200e18); // settler needs wstETH to fund settleBatch()

        // Configure settler in vault.
        vault.setSettler(SETTLER);

        console2.log("setUp: environment deployed");
        console2.log("  vault   :", address(vault));
        console2.log("  trancher:", address(trancher));
        console2.log("  pToken  :", address(pToken));
        console2.log("  nToken  :", address(nToken));
    }

    /* ///////////////////////////////////////////////////////////////
         TEST 1 — GENESIS DEPOSIT BOOTSTRAP
    ///////////////////////////////////////////////////////////////
         Proves the state-ordering fix in Vault.deposit():
           Trancher.split() is called BEFORE totalDeposited is incremented.
           At the moment split() executes, totalDepositedAssets() == 0.
           Trancher._currentCoverage() reads 0 → genesis path:
             100% coverage → 100% P tokens, 0 N tokens.
         If the ordering were reversed (increment first), the first depositor
         would see coverage = 0 and receive all N tokens — the exact opposite
         of the intended behaviour.
    /////////////////////////////////////////////////////////////// */

    function test_GenesisDepositBootstrap() public {
        console2.log("--- test_GenesisDepositBootstrap ---");

        uint256 depositAmount = 10e18;

        vm.startPrank(ALICE);
        wstETH.approve(address(vault), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, ALICE);
        vm.stopPrank();

        uint256 vaultShares = vault.balanceOf(ALICE);
        uint256 pBalance = pToken.balanceOf(ALICE);
        uint256 nBalance = nToken.balanceOf(ALICE);

        console2.log("sharesReceived:", sharesReceived);
        console2.log("pBalance      :", pBalance);
        console2.log("nBalance      :", nBalance);

        // Solady ERC4626 with _decimalsOffset = 0: on an empty vault,
        //   shares = assets × (totalSupply + 1) / (totalAssets + 1) = assets × 1/1 = assets.
        assertEq(sharesReceived, depositAmount, "Genesis: shares must be 1:1 with deposited assets on first deposit");
        assertEq(vaultShares, depositAmount, "Genesis: vault balance must equal deposited amount");

        // State-ordering fix proof:
        // split() fires at totalDepositedAssets() == 0 → genesis bootstrap → all P.
        assertEq(
            pBalance,
            depositAmount,
            "Genesis: depositor must receive P tokens equal to deposit (split() before increment)"
        );
        assertEq(nBalance, 0, "Genesis: depositor must receive zero N tokens");

        // Core supply invariant.
        assertEq(pBalance + nBalance, vaultShares, "Invariant: P + N must equal vault shares at all times");

        console2.log("PASS");
    }

    /* ///////////////////////////////////////////////////////////////
         TEST 2 — TVL IMBALANCE TRIGGERS REBALANCE
    ///////////////////////////////////////////////////////////////
         Proves the new Perp-model rebalance trigger:
           When vault TVL diverges from the perp notional by > 1%,
           checkAndEmitIntent() emits IntentRequested with the signed
           size delta (positive = vault needs MORE short notional).

         Scenario:
           1. ALICE deposits 100 wstETH (genesis → 100% P).
           2. Open a perp position of only 50 wstETH notional (50% hedged).
           3. TVL = 100, perpNotional = 50 → imbalance = 50 → 50% >> 1%.
           4. IntentRequested fires with sizeDelta = +50e18.
    /////////////////////////////////////////////////////////////// */

    function test_TVLImbalanceTriggersRebalance() public {
        console2.log("--- test_TVLImbalanceTriggersRebalance ---");

        // Seed vault.
        _deposit(ALICE, 100e18);

        // Open perp at only 50% of TVL → 50 wstETH notional (50 under-hedged).
        adapter.openPosition(50e18);

        uint256 tvl = vault.totalDepositedAssets();
        uint256 perpNotional = adapter.totalHedgedNotional();

        console2.log("TVL (wstETH)          :", tvl);
        console2.log("perpNotional (wstETH) :", perpNotional);

        // sizeDelta = TVL - perpNotional = 100 - 50 = +50e18 (need to increase short).
        int256 expectedSizeDelta = int256(tvl) - int256(perpNotional);
        console2.log("expectedSizeDelta     :", expectedSizeDelta);

        assertGt(
            tvl - perpNotional, (tvl * IMBALANCE_THRESHOLD_BPS) / 10_000, "Sanity: imbalance must exceed 1% threshold"
        );

        // Expect IntentRequested with positive size delta (under-hedged).
        vm.expectEmit(true, false, false, true, address(vault));
        emit IVault.IntentRequested(expectedSizeDelta, block.timestamp);

        vault.checkAndEmitIntent();

        console2.log("PASS: IntentRequested fired with correct size delta");
    }

    /* ///////////////////////////////////////////////////////////////
         TEST 3 — POSITIVE FUNDING ACCRUES YIELD
    ///////////////////////////////////////////////////////////////
         Proves the Perp funding model:
           accruedFunding = fundingRatePerBlock × blocks × totalHedgedNotional / 1e18
         When funding is positive (longs pay shorts), the vault EARNS.
         Scaling: doubling the notional doubles the accrued funding (linear).
    /////////////////////////////////////////////////////////////// */

    function test_PositiveFundingAccruesYield() public {
        console2.log("--- test_PositiveFundingAccruesYield ---");

        _deposit(ALICE, 50e18);

        // Open a position: 50 wstETH notional.
        uint256 notional1 = 50e18;
        adapter.openPosition(notional1);

        // Set a clearly positive funding rate.
        int256 fundingRate = 1e12; // positive = longs pay shorts = vault earns
        adapter.setMockFundingRate(fundingRate);

        // At t=0 (no blocks elapsed since openPosition): accruedFunding = 0.
        assertEq(adapter.accruedFunding(), 0, "No funding accrued before any blocks pass");

        // Fast-forward 100 blocks.
        uint256 blocks = 100;
        vm.roll(block.number + blocks);

        // Verify accrual: rate × blocks × notional / 1e18.
        int256 accrued1 = adapter.accruedFunding();
        int256 expected1 = fundingRate * int256(blocks) * int256(notional1) / 1e18;

        console2.log("fundingRatePerBlock:", fundingRate);
        console2.log("blocks             :", blocks);
        console2.log("notional1          :", notional1);
        console2.log("accrued1           :", accrued1);
        console2.log("expected1          :", expected1);

        assertEq(accrued1, expected1, "accruedFunding must equal rate * blocks * notional / 1e18");
        assertGt(accrued1, 0, "Funding must be strictly positive (vault earns) after blocks have passed");

        // --- Prove linear scaling with notional ---
        // Settle (reset block counter), then double the position.
        adapter.settleFunding();
        uint256 posId2 = uint256(adapter.openPosition(notional1)); // total = 2 × notional1
        (posId2); // silence unused warning

        vm.roll(block.number + blocks);

        int256 accrued2 = adapter.accruedFunding();
        int256 expected2 = fundingRate * int256(blocks) * int256(notional1 * 2) / 1e18;

        console2.log("accrued2 (2x notional):", accrued2);
        console2.log("expected2             :", expected2);

        assertEq(accrued2, expected2, "Double notional must produce exactly double funding (linear scaling)");
        assertEq(accrued2, accrued1 * 2, "accrued2 must be exactly twice accrued1 -- proves proportionality");

        console2.log("PASS: positive funding scales linearly with hedged notional");
    }

    /* ///////////////////////////////////////////////////////////////
         TEST 4 — REDEEM TRANCHED (CUSTOM RATIOS)
    ///////////////////////////////////////////////////////////////
         Scenario:
           ALICE deposit 1 at genesis    → 10e18 shares, 10e18 P, 0 N
           Open 50% perp hedge (5 wstETH on 10 wstETH TVL)
           ALICE deposit 2 at 50% coverage → 10e18 more shares, 5e18 P, 5e18 N
           ALICE calls redeemTranched(sharesToRedeem=5e18, pToBurn=0, nToBurn=5e18)
             → burns ONLY N tokens (non-standard custom ratio)
         Invariant verified after: pSupply + nSupply == vault.totalSupply()
    /////////////////////////////////////////////////////////////// */

    function test_RedeemTranched_CustomRatios() public {
        console2.log("--- test_RedeemTranched_CustomRatios ---");

        // ---- Step 1: Genesis deposit → 100% P ----
        _deposit(ALICE, 10e18);
        uint256 sharesAfterDeposit1 = vault.balanceOf(ALICE);

        assertEq(pToken.balanceOf(ALICE), sharesAfterDeposit1, "Step 1: genesis must produce all P tokens");
        assertEq(nToken.balanceOf(ALICE), 0, "Step 1: genesis must produce zero N tokens");

        // ---- Step 2: Open a 50% perp hedge ----
        // TVL = 10 wstETH. Hedge half = 5 wstETH notional.
        adapter.openPosition(5e18);

        // Verify coverage is ~50%: perpNotional(5) / TVL(10) = 50%.
        uint256 coverage = vault.hedgeCoverage();
        assertApproxEqAbs(coverage, 0.5e18, 1, "Step 2: coverage must be ~50%");

        // ---- Step 3: Second deposit at 50% coverage → mix of P and N ----
        _deposit(ALICE, 10e18);

        uint256 totalShares = vault.balanceOf(ALICE);
        uint256 pBalancePre = pToken.balanceOf(ALICE); // 10e18 + 5e18 = 15e18
        uint256 nBalancePre = nToken.balanceOf(ALICE); // 0    + 5e18 = 5e18

        console2.log("After 2nd deposit:");
        console2.log("  totalShares :", totalShares);
        console2.log("  pBalance    :", pBalancePre);
        console2.log("  nBalance    :", nBalancePre);

        assertGt(nBalancePre, 0, "Step 3: ALICE must hold N tokens after depositing at partial coverage");
        assertEq(pBalancePre + nBalancePre, totalShares, "Step 3: P + N must equal total shares before redemption");

        // ---- Step 4: Redeem using ONLY N tokens (non-standard ratio) ----
        uint256 sharesToRedeem = nBalancePre;
        uint256 pToBurn = 0;
        uint256 nToBurn = nBalancePre;

        uint256 pSupplyBefore = pToken.totalSupply();
        uint256 nSupplyBefore = nToken.totalSupply();
        uint256 vSupplyBefore = vault.totalSupply();
        uint256 wstBefore = wstETH.balanceOf(ALICE);

        console2.log("Redeeming:");
        console2.log("  sharesToRedeem:", sharesToRedeem);
        console2.log("  pToBurn       :", pToBurn);
        console2.log("  nToBurn       :", nToBurn);

        vm.startPrank(ALICE);
        vault.approve(address(vault), sharesToRedeem);
        uint256 returned = vault.redeemTranched(
            sharesToRedeem,
            ALICE, // receiver of wstETH
            ALICE, // owner of shares + tokens
            pToBurn,
            nToBurn
        );
        vm.stopPrank();

        console2.log("wstETH returned :", returned);

        // ---- Step 5: Verify post-redemption state ----
        assertGt(returned, 0, "Redemption must return positive wstETH");
        assertEq(
            wstETH.balanceOf(ALICE), wstBefore + returned, "ALICE's wstETH balance must increase by the returned amount"
        );

        assertEq(nToken.balanceOf(ALICE), 0, "All N tokens must be burned after N-only redemption");
        assertEq(pToken.balanceOf(ALICE), pBalancePre, "P token balance must be unchanged (pToBurn == 0)");

        assertEq(pToken.totalSupply(), pSupplyBefore, "P total supply must be unchanged");
        assertEq(nToken.totalSupply(), nSupplyBefore - nToBurn, "N total supply must decrease by exactly nToBurn");
        assertEq(
            vault.totalSupply(), vSupplyBefore - sharesToRedeem, "Vault shares must decrease by exactly sharesToRedeem"
        );

        // Core invariant: pSupply + nSupply == vaultShares at all times.
        assertEq(
            pToken.totalSupply() + nToken.totalSupply(),
            vault.totalSupply(),
            "Invariant: pSupply + nSupply must equal vault.totalSupply() after custom-ratio redeem"
        );

        console2.log("PASS: redeemTranched with N-only ratio satisfies all invariants");
    }

    /* ///////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    /////////////////////////////////////////////////////////////// */

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        wstETH.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
         TEST 5 — REQUEST REDEEM LOCKS SHARES + BURNS TRANCHE TOKENS
    ///////////////////////////////////////////////////////////////
         Proves Phase 1 of the async batch exit lifecycle.
         At requestRedeem time:
           - P+N tokens are burned immediately (tranche invariant evaluated now)
           - Vault shares move from user to vault contract (locked)
           - assetsLocked = previewRedeem(shares) at request block
           - pSupply + nSupply == totalSupply invariant holds
    /////////////////////////////////////////////////////////////// */

    function test_RequestRedeem_LocksSharesBurnsTrancheTokens() public {
        console2.log("--- test_RequestRedeem_LocksSharesBurnsTrancheTokens ---");

        _deposit(ALICE, 10e18);

        uint256 shares = vault.balanceOf(ALICE);
        uint256 pBal = pToken.balanceOf(ALICE);
        uint256 nBal = nToken.balanceOf(ALICE);
        assertEq(pBal, shares, "Genesis: all P");
        assertEq(nBal, 0, "Genesis: no N");

        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 assetsLockedExpected = vault.previewRedeem(shares);

        vm.startPrank(ALICE);
        vault.approve(address(vault), shares);
        bytes32 requestId = vault.requestRedeem(shares, ALICE, ALICE, pBal, 0, 0);
        vm.stopPrank();

        // P+N burned.
        assertEq(pToken.balanceOf(ALICE), 0, "P burned at request time");
        assertEq(nToken.balanceOf(ALICE), 0, "N burned at request time");

        // Shares locked.
        assertEq(vault.balanceOf(ALICE), 0, "ALICE has no shares after request");
        assertEq(vault.balanceOf(address(vault)), shares, "Vault holds ALICE shares");
        assertEq(vault.totalSupply(), totalSupplyBefore, "totalSupply not burned until settlement");

        // Batch updated.
        BatchTypes.BatchInfo memory batch = vault.getBatch(vault.getRequest(requestId).batchId);
        assertEq(batch.totalSharesQueued, shares);
        assertApproxEqAbs(batch.totalAssetsLocked, assetsLockedExpected, 1);

        // Invariant: pSupply + nSupply == totalSupply - pendingRedemption.
        // P+N are burned at requestRedeem time, but vault shares only burn at settleBatch.
        // The delta (totalPendingRedemption) represents "orphaned" supply with no tranche backing.
        assertEq(
            pToken.totalSupply() + nToken.totalSupply(),
            vault.totalSupply() - vault.totalPendingRedemption(),
            "INVARIANT: pSupply + nSupply == totalSupply - totalPendingRedemption after requestRedeem"
        );

        console2.log("PASS");
    }

    /* ///////////////////////////////////////////////////////////////
         TEST 6 — SETTLE BATCH RELEASES ASSETS TO SINGLE CLAIMER
    ///////////////////////////////////////////////////////////////
         Proves the full 3-phase lifecycle for a single user:
           Phase 1: requestRedeem
           Phase 2: closeBatch + settleBatch (settler funds from bridged wstETH)
           Phase 3: claimRedeemedAssets
    /////////////////////////////////////////////////////////////// */

    function test_SettleBatch_ReleasesAssetsToSingleClaimer() public {
        console2.log("--- test_SettleBatch_ReleasesAssetsToSingleClaimer ---");

        _deposit(ALICE, 10e18);

        uint256 shares = vault.balanceOf(ALICE);
        uint256 pBal = pToken.balanceOf(ALICE);

        // Phase 1.
        vm.startPrank(ALICE);
        vault.approve(address(vault), shares);
        bytes32 requestId = vault.requestRedeem(shares, ALICE, ALICE, pBal, 0, 0);
        vm.stopPrank();

        bytes32 batchId = vault.getRequest(requestId).batchId;

        // Phase 2a: close.
        vm.prank(SETTLER);
        vault.closeBatch();

        assertTrue(vault.getBatch(batchId).isClosed);

        uint128 bridgedAssets = 10e18;
        uint256 aliceWstBefore = wstETH.balanceOf(ALICE);

        // Phase 2b: settle (settler bridges wstETH back).
        vm.startPrank(SETTLER);
        wstETH.approve(address(vault), bridgedAssets);
        vault.settleBatch(batchId, bridgedAssets);
        vm.stopPrank();

        assertTrue(vault.getBatch(batchId).isSettled, "Batch must be settled");
        assertEq(vault.totalSupply(), 0, "All locked shares burned at settlement");

        // Phase 3: claim.
        vm.prank(ALICE);
        uint256 claimed = vault.claimRedeemedAssets(requestId);

        assertEq(claimed, bridgedAssets, "Single claimer gets full bridged amount");
        assertEq(wstETH.balanceOf(ALICE), aliceWstBefore + claimed, "ALICE receives wstETH");
        assertEq(
            uint8(vault.getRequest(requestId).status),
            uint8(BatchTypes.RequestStatus.CLAIMED),
            "Request status must be CLAIMED"
        );

        console2.log("PASS: claimed =", claimed);
    }

    /* ///////////////////////////////////////////////////////////////
         TEST 7 — PRO-RATA DISTRIBUTION ACROSS TWO USERS
    ///////////////////////////////////////////////////////////////
         ALICE (6 wstETH, genesis -> all P) and BOB (4 wstETH, 0% coverage -> all N)
         both request redeem. settleBatch returns 9 wstETH (10% bridge slippage).
         Each user receives their proportional share of the returned assets.
    /////////////////////////////////////////////////////////////// */

    function test_SettleBatch_ProRata_TwoUserDistribution() public {
        console2.log("--- test_SettleBatch_ProRata_TwoUserDistribution ---");

        _deposit(ALICE, 6e18);
        _deposit(BOB, 4e18);

        uint256 aliceShares = vault.balanceOf(ALICE);
        uint256 bobShares = vault.balanceOf(BOB);

        // Both request redeem.
        vm.startPrank(ALICE);
        vault.approve(address(vault), aliceShares);
        bytes32 aliceReqId =
            vault.requestRedeem(aliceShares, ALICE, ALICE, pToken.balanceOf(ALICE), nToken.balanceOf(ALICE), 0);
        vm.stopPrank();

        vm.startPrank(BOB);
        vault.approve(address(vault), bobShares);
        bytes32 bobReqId = vault.requestRedeem(bobShares, BOB, BOB, pToken.balanceOf(BOB), nToken.balanceOf(BOB), 0);
        vm.stopPrank();

        bytes32 batchId = vault.getRequest(aliceReqId).batchId;
        assertEq(vault.getRequest(bobReqId).batchId, batchId, "Same batch");

        // Close + settle with 10% slippage.
        uint128 bridgedAssets = 9e18;

        vm.prank(SETTLER);
        vault.closeBatch();

        vm.startPrank(SETTLER);
        wstETH.approve(address(vault), bridgedAssets);
        vault.settleBatch(batchId, bridgedAssets);
        vm.stopPrank();

        // Compute expected pro-rata amounts.
        BatchTypes.BatchInfo memory batch = vault.getBatch(batchId);
        uint256 aliceLocked = vault.getRequest(aliceReqId).assetsLocked;
        uint256 bobLocked = vault.getRequest(bobReqId).assetsLocked;
        uint256 totalLocked = batch.totalAssetsLocked;

        uint256 expAlice = (bridgedAssets * aliceLocked) / totalLocked;
        uint256 expBob = (bridgedAssets * bobLocked) / totalLocked;

        // Both claim.
        vm.prank(ALICE);
        uint256 aliceClaimed = vault.claimRedeemedAssets(aliceReqId);
        vm.prank(BOB);
        uint256 bobClaimed = vault.claimRedeemedAssets(bobReqId);

        console2.log("aliceClaimed:", aliceClaimed);
        console2.log("bobClaimed:  ", bobClaimed);
        console2.log("expAlice:    ", expAlice);
        console2.log("expBob:      ", expBob);

        assertApproxEqAbs(aliceClaimed, expAlice, 1, "Alice pro-rata");
        assertApproxEqAbs(bobClaimed, expBob, 1, "Bob pro-rata");
        assertLe(
            aliceClaimed + bobClaimed, uint256(bridgedAssets) + 2, "Total claims <= bridged assets (no over-payout)"
        );

        console2.log("PASS");
    }
}
