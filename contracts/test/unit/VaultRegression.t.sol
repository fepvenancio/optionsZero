// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {Vault} from "../../src/core/Vault.sol";
import {Trancher} from "../../src/core/Trancher.sol";
import {PToken} from "../../src/tokens/PToken.sol";
import {NToken} from "../../src/tokens/NToken.sol";
import {MockPerpAdapter} from "../../src/hedge/MockPerpAdapter.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {ITrancher} from "../../src/interfaces/ITrancher.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/* ///////////////////////////////////////////////////////////////
                      INLINE TEST DOUBLES
/////////////////////////////////////////////////////////////// */

contract MockAsset is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock wstETH";
    }

    function symbol() public pure override returns (string memory) {
        return "mwstETH";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal wstETH pricer — returns 1:1 USD (1 wstETH = $1 for simplicity).
contract UnitPricer {
    function getEthUsdPrice() external pure returns (uint256) {
        return 1e8;
    }

    function getWstETHRate() external pure returns (uint256) {
        return 1e18;
    }

    function wstETHToUSD(uint256 wstETHAmount) external pure returns (uint256) {
        return wstETHAmount; // 1 wstETH = $1 (unit scale, test-only)
    }
}

/* ///////////////////////////////////////////////////////////////
            REGRESSION TEST SUITE — Vault PERP ACCOUNTING
/////////////////////////////////////////////////////////////// */

/// @title  VaultRegressionTest
/// @notice Regression guard for the perp size-imbalance rebalancing logic.
///
///         Regressions 1 & 2 from the original options system (delta infinite loop
///         and inverted direction) are replaced by perp-equivalent tests:
///
///         REGRESSION 1 — NO REBALANCE WHEN BALANCED:
///           When perpNotional == totalDepositedAssets (fully sized), no intent fires.
///
///         REGRESSION 2 — SIZE DELTA CARRIED IN EVENT:
///           When there is a significant size imbalance the event payload carries
///           the correct signed size delta (positive = under-hedged, negative = over-hedged).
///
///         REGRESSION 3 — TRANCHE LOCKUP (MERGE INVARIANT):
///           Kept unchanged — pure P or pure N holders must always be redeemable.
///
///         REGRESSION 4 — ROUNDING DRIFT (pBurned + nBurned == shares):
///           Kept unchanged — addition constraint eliminates rounding drift.
///
///         REGRESSION 5 — FLASH LOAN / DONATION RESISTANCE:
///           Kept unchanged — totalDepositedAssets immune to direct donations.
///
/// @dev    All tests are marked with "REGRESSION:" in their failure messages so
///         they are immediately identifiable in CI output.
contract VaultRegressionTest is Test {
    Vault internal vault;
    MockPerpAdapter internal adapter;
    MockAsset internal asset;

    bytes32 internal constant INTENT_TOPIC = keccak256("IntentRequested(int256,uint256)");

    /// @dev IMBALANCE_THRESHOLD_BPS from Vault = 100 (1%).
    uint256 internal constant IMBALANCE_THRESHOLD_BPS = 100;

    function setUp() public {
        asset = new MockAsset();
        adapter = new MockPerpAdapter();

        // Deploy a minimal vault: trancher = address(0) (no deposits in these tests).
        vault = new Vault(address(asset), address(0), address(adapter));
    }

    /* ///////////////////////////////////////////////////////////////
         REGRESSION 1 — NO REBALANCE WHEN BALANCED
    ///////////////////////////////////////////////////////////////
         When the perp notional exactly matches vault TVL (fully sized),
         checkAndEmitIntent() must stay silent.
         Old options regression: DITM delta caused infinite trigger loop.
         Perp equivalent: constant delta = -1 never needs rebalancing on price moves.
    /////////////////////////////////////////////////////////////// */

    /// @notice When perpNotional == totalDepositedAssets (both zero), no intent fires.
    function test_Regression1_NoRebalanceWhenBalanced_ZeroTVL() public {
        // No deposits, no perp positions → both sides are 0 → balanced.
        vm.recordLogs();
        vault.checkAndEmitIntent();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == INTENT_TOPIC) {
                fail("REGRESSION 1: Balanced vault (both zero) must NOT fire IntentRequested");
            }
        }
    }

    /// @notice When perpNotional == totalDepositedAssets (non-zero), no intent fires.
    function test_Regression1_NoRebalanceWhenBalanced_NonZeroTVL() public {
        // Deposit 10 wstETH via the standard path (uses full-stack setUp).
        _setUpFullStack();

        vm.startPrank(ALICE);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, ALICE);
        vm.stopPrank();

        // Open perp position with exact matching notional (10 wstETH).
        adapter.openPosition(10e18);

        // Perp notional == totalDepositedAssets → imbalance = 0 → no intent.
        vm.recordLogs();
        vault.checkAndEmitIntent();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == INTENT_TOPIC) {
                fail("REGRESSION 1: Fully balanced perp must NOT emit IntentRequested");
            }
        }
    }

    /* ///////////////////////////////////////////////////////////////
         REGRESSION 2 — SIZE DELTA CARRIED IN EVENT
    ///////////////////////////////////////////////////////////////
         When there is a >1% size imbalance, the event must carry the
         correct SIGNED size delta:
           positive sizeDelta → vault under-hedged (need to open more short)
           negative sizeDelta → vault over-hedged  (need to reduce short)
    /////////////////////////////////////////////////////////////// */

    /// @notice Under-hedged: deposited=10 wstETH, perpNotional=5 wstETH → 50% imbalance.
    ///         sizeDelta = +5e18 (need 5 more wstETH of short).
    function test_Regression2_SizeDeltaCarriedInEvent_UnderHedged() public {
        _setUpFullStack();

        vm.startPrank(ALICE);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, ALICE);
        vm.stopPrank();

        // Open only 5 wstETH of perp (50% coverage — large imbalance).
        adapter.openPosition(5e18);

        int256 expectedSizeDelta = 5e18; // deposited(10) - notional(5) = +5

        vm.expectEmit(true, false, false, true, address(vault));
        emit IVault.IntentRequested(expectedSizeDelta, block.timestamp);

        vault.checkAndEmitIntent();
    }

    /// @notice Over-hedged: deposited=10 wstETH, perpNotional=15 wstETH → -5e18 delta.
    function test_Regression2_SizeDeltaCarriedInEvent_OverHedged() public {
        _setUpFullStack();

        vm.startPrank(ALICE);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, ALICE);
        vm.stopPrank();

        // Open 15 wstETH perp on 10 wstETH TVL → 50% over-hedge.
        adapter.openPosition(15e18);

        int256 expectedSizeDelta = -5e18; // deposited(10) - notional(15) = -5

        vm.expectEmit(true, false, false, true, address(vault));
        emit IVault.IntentRequested(expectedSizeDelta, block.timestamp);

        vault.checkAndEmitIntent();
    }

    /// @notice Fuzz: for any imbalance > 1% threshold, event delta sign is correct.
    function testFuzz_Regression2_EventSignMatchesImbalanceDirection(uint64 deposited, uint64 notional) public {
        vm.assume(deposited > 0);
        // imbalance > 1% of deposited
        uint256 dep = uint256(deposited);
        uint256 not_ = uint256(notional);
        uint256 imbalance = dep > not_ ? dep - not_ : not_ - dep;
        uint256 threshold = (dep * IMBALANCE_THRESHOLD_BPS) / 10_000;
        vm.assume(imbalance > threshold);

        // Wire vault with correct deposited balance via full stack.
        _setUpFullStack();
        asset.mint(ALICE, dep);
        vm.startPrank(ALICE);
        asset.approve(address(vault), dep);
        vault.deposit(dep, ALICE);
        vm.stopPrank();

        if (not_ > 0) adapter.openPosition(not_);

        vm.recordLogs();
        vault.checkAndEmitIntent();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == INTENT_TOPIC) {
                int256 emittedDelta = int256(uint256(logs[i].topics[1]));
                if (dep > not_) {
                    assertGt(emittedDelta, 0, "REGRESSION 2: Under-hedged -> positive delta");
                } else {
                    assertLt(emittedDelta, 0, "REGRESSION 2: Over-hedged -> negative delta");
                }
                found = true;
            }
        }
        assertTrue(found, "REGRESSION 2: Expected IntentRequested not found");
    }

    /* ///////////////////////////////////////////////////////////////
         REGRESSION 3 — TRANCHE LOCKUP (MERGE INVARIANT)
    /////////////////////////////////////////////////////////////// */

    UnitPricer internal pricer;
    Trancher internal trancher;
    PToken internal pToken;
    NToken internal nToken;

    address internal ALICE;
    address internal BOB;

    /// @dev Re-deploy with a full stack (needed for deposit/redeem path).
    function _setUpFullStack() internal {
        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");
        pricer = new UnitPricer();

        uint64 nonce = vm.getNonce(address(this));
        address ptAddr = vm.computeCreateAddress(address(this), nonce);
        address ntAddr = vm.computeCreateAddress(address(this), nonce + 1);
        address trAddr = vm.computeCreateAddress(address(this), nonce + 2);
        address vaAddr = vm.computeCreateAddress(address(this), nonce + 3);

        pToken = new PToken(trAddr);
        nToken = new NToken(trAddr);
        trancher = new Trancher(vaAddr, ptAddr, ntAddr, address(adapter), address(pricer));
        vault = new Vault(address(asset), trAddr, address(adapter));

        asset.mint(ALICE, 100e18);
        asset.mint(BOB, 100e18);
    }

    /// @notice A user who deposited at genesis (all-P) can always redeem — no N required.
    ///
    ///         This is the exact "portfolio lockup" scenario from the audit:
    ///           ALICE deposits at 100% coverage → holds only P tokens.
    ///           Global pool shifts → naive global-ratio merge demands N she doesn't own.
    ///           Fix: ALICE calls redeemTranched(shares, _, _, shares, 0) — only P burned.
    function test_Regression3a_POnlyHolder_AlwaysRedeemable() public {
        _setUpFullStack();

        // Genesis deposit: coverage = 100% → ALICE gets all P, no N.
        vm.startPrank(ALICE);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, ALICE);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(ALICE);
        assertEq(pToken.balanceOf(ALICE), shares, "Setup: ALICE must hold only P");
        assertEq(nToken.balanceOf(ALICE), 0, "Setup: ALICE must hold no N");

        // BOB deposits with NO hedge → all N (shifts global supply away from genesis).
        vm.startPrank(BOB);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, BOB);
        vm.stopPrank();

        // Global: pSupply=10e18, nSupply=10e18. Old code would demand 5 N from ALICE → revert.
        // New code: computeMerge greedy P-first → (10e18, 0) → succeeds.
        vm.startPrank(ALICE);
        vault.approve(address(vault), shares);
        uint256 returned = vault.redeem(shares, ALICE, ALICE);
        vm.stopPrank();

        assertGt(returned, 0, "REGRESSION 3a: P-only holder must receive wstETH on redeem");
        assertEq(pToken.balanceOf(ALICE), 0, "REGRESSION 3a: All P must be burned");
    }

    /// @notice A user who holds only N tokens can redeem explicitly via redeemTranched.
    function test_Regression3b_NOnlyHolder_AlwaysRedeemable() public {
        _setUpFullStack();

        // ALICE deposits first (genesis → all P, establishes non-zero totalDeposited).
        vm.startPrank(ALICE);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, ALICE);
        vm.stopPrank();

        // BOB deposits after — no hedge open → all N.
        vm.startPrank(BOB);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, BOB);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(BOB);
        assertEq(pToken.balanceOf(BOB), 0, "Setup: BOB must hold only N");
        assertEq(nToken.balanceOf(BOB), shares, "Setup: BOB must hold all N");

        // BOB redeems using redeemTranched with (0, shares).
        vm.startPrank(BOB);
        vault.approve(address(vault), shares);
        uint256 returned = vault.redeemTranched(shares, BOB, BOB, 0, shares);
        vm.stopPrank();

        assertGt(returned, 0, "REGRESSION 3b: N-only holder must receive wstETH on redeem");
        assertEq(nToken.balanceOf(BOB), 0, "REGRESSION 3b: All N must be burned");
    }

    /* ///////////////////////////////////////////////////////////////
         REGRESSION 4 — ROUNDING DRIFT (pBurned + nBurned == shares)
    /////////////////////////////////////////////////////////////// */

    /// @notice Invariant: for any merge, pBurned + nBurned == shares exactly.
    ///         The old code used two independent floor-divisions, so the total could
    ///         be 1 or 2 wei short, accumulating over thousands of redemptions.
    ///
    ///         Tested here at the vault level (via Trancher.computeMerge + merge).
    function testFuzz_Regression4_NoDriftOnMerge(uint128 pAmt, uint128 nAmt) public {
        _setUpFullStack();

        vm.assume(uint256(pAmt) + uint256(nAmt) > 0);
        uint256 shares = uint256(pAmt) + uint256(nAmt);

        // Mint tokens directly to ALICE (bypass deposit to get exact amounts).
        vm.startPrank(address(trancher));
        if (pAmt > 0) pToken.mint(ALICE, pAmt);
        if (nAmt > 0) nToken.mint(ALICE, nAmt);
        vm.stopPrank();

        // computeMerge + merge through the trancher (as vault would call it).
        (uint256 pToBurn, uint256 nToBurn) = trancher.computeMerge(ALICE, shares);
        vm.prank(address(vault));
        (uint256 pBurned, uint256 nBurned) = trancher.merge(ALICE, shares, pToBurn, nToBurn);

        assertEq(
            pBurned + nBurned, shares, "REGRESSION 4: pBurned + nBurned must equal shares exactly -- no rounding drift"
        );
    }

    /* ///////////////////////////////////////////////////////////////
         REGRESSION 5 — FLASH LOAN / DONATION RESISTANCE
    /////////////////////////////////////////////////////////////// */

    /// @notice totalDepositedAssets() must NOT change when wstETH is sent directly
    ///         to the vault address (bypassing deposit() hooks).
    ///
    ///         The old coverage denominator read totalAssets() = raw ERC-20 balance,
    ///         which IS inflatable by donation → manipulates coverage ratio.
    ///         The fix reads totalDepositedAssets() which only moves via hooks.
    function test_Regression5_DirectDonation_DoesNotChangeTotalDeposited() public {
        _setUpFullStack();

        // Legitimate deposit: 10e18 wstETH via deposit().
        vm.startPrank(ALICE);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, ALICE);
        vm.stopPrank();

        uint256 depositedBefore = vault.totalDepositedAssets();
        uint256 assetsBefore = vault.totalAssets();

        // Attacker donates 1000e18 wstETH directly (bypass hooks).
        asset.mint(address(vault), 1000e18);

        uint256 depositedAfter = vault.totalDepositedAssets();
        uint256 assetsAfter = vault.totalAssets();

        assertEq(
            depositedAfter, depositedBefore, "REGRESSION 5: totalDepositedAssets must be immune to direct donations"
        );
        assertGt(assetsAfter, assetsBefore, "Control: totalAssets() IS inflatable (raw balance -- this is expected)");
        assertGt(assetsAfter - assetsBefore, 999e18, "Control: donation must be reflected in totalAssets()");
    }
}
