// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {Vault} from "../../src/core/Vault.sol";
import {Trancher} from "../../src/core/Trancher.sol";
import {YieldAccumulator} from "../../src/core/YieldAccumulator.sol";
import {PToken} from "../../src/tokens/PToken.sol";
import {NToken} from "../../src/tokens/NToken.sol";
import {MockPerpAdapter} from "../../src/hedge/MockPerpAdapter.sol";
import {IVault} from "../../src/interfaces/IVault.sol";

/* ///////////////////////////////////////////////////////////////
                      INLINE TEST DOUBLES
/////////////////////////////////////////////////////////////// */

/// @dev ERC-20 representing mock wstETH. Mint freely in tests.
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

/// @dev Pricer: fixed $3,300/wstETH (1.1 stETH × $3,000), wstETH rate = 1.1.
///      Used by YieldAccumulator; not used by Trancher in the Perp model.
contract FixedPricer {
    function getEthUsdPrice() external pure returns (uint256) {
        return 3_000e8;
    }

    function getWstETHRate() external pure returns (uint256) {
        return 1.1e18;
    }

    function wstETHToUSD(uint256 wstETHAmount) external pure returns (uint256) {
        return (wstETHAmount * 3_300e18) / 1e18;
    }
}

/* ///////////////////////////////////////////////////////////////
                         E2E INTEGRATION TEST
/////////////////////////////////////////////////////////////// */

/// @title  E2ETest
/// @notice Full-stack integration test for the OptionZero Perp model.
///
///         Deployment order (respects constructor dependency graph):
///           1. MockWstETH, MockPerpAdapter, FixedPricer — no deps
///           2. PToken, NToken, Trancher (pre-computed addresses)
///           3. Vault
///           4. YieldAccumulator
///
///         Key changes from Options model:
///           - MockPerpAdapter replaces MockOptionAdapter (constant delta -1.0, no gamma)
///           - Rebalance trigger: TVL vs perpNotional imbalance > 1% (not delta drift)
///           - Funding replaces theta: signed, scales with notional, positive = vault earns
contract E2ETest is Test {
    MockWstETH internal wstETH;
    MockPerpAdapter internal adapter;
    FixedPricer internal pricer;
    PToken internal pToken;
    NToken internal nToken;
    Trancher internal trancher;
    Vault internal vault;
    YieldAccumulator internal yieldAccum;

    address internal ALICE;
    address internal BOB;

    /* ///////////////////////////////////////////////////////////////
                               SETUP
    /////////////////////////////////////////////////////////////// */

    function setUp() public {
        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");

        wstETH = new MockWstETH();
        adapter = new MockPerpAdapter();
        pricer = new FixedPricer();

        // --- Compute addresses before deployment using forge's helper ---
        // Deploy order: pToken(0), nToken(1), trancher(2), vault(3)
        uint64 startNonce = vm.getNonce(address(this));

        address pTokenAddr = vm.computeCreateAddress(address(this), startNonce);
        address nTokenAddr = vm.computeCreateAddress(address(this), startNonce + 1);
        address trancherAddr = vm.computeCreateAddress(address(this), startNonce + 2);
        address vaultAddr = vm.computeCreateAddress(address(this), startNonce + 3);

        // Deploy in pre-computed order.
        pToken = new PToken(trancherAddr); // nonce + 0
        nToken = new NToken(trancherAddr); // nonce + 1
        trancher = new Trancher( // nonce + 2
            vaultAddr,
            pTokenAddr,
            nTokenAddr,
            address(adapter),
            address(pricer)
        );
        vault = new Vault(address(wstETH), trancherAddr, address(adapter)); // nonce + 3

        // Verify all pre-computations were correct.
        assertEq(address(pToken), pTokenAddr, "pToken addr mismatch");
        assertEq(address(nToken), nTokenAddr, "nToken addr mismatch");
        assertEq(address(trancher), trancherAddr, "trancher addr mismatch");
        assertEq(address(vault), vaultAddr, "vault addr mismatch");

        // YieldAccumulator — no address dependency issues.
        yieldAccum = new YieldAccumulator(address(vault), address(pricer), address(adapter));

        // Seed users.
        wstETH.mint(ALICE, 100e18);
        wstETH.mint(BOB, 50e18);
    }

    /* ///////////////////////////////////////////////////////////////
                       1. DEPOSIT → TRANCHE MINT
    /////////////////////////////////////////////////////////////// */

    /// @notice Genesis deposit: empty vault → 100% coverage → all P tokens.
    function test_Deposit_Genesis_MintsAllP() public {
        _deposit(ALICE, 10e18);

        uint256 shares = vault.balanceOf(ALICE);
        assertGt(shares, 0, "Must have vault shares");
        assertEq(pToken.balanceOf(ALICE), shares, "Genesis: all shares = P tokens");
        assertEq(nToken.balanceOf(ALICE), 0, "Genesis: no N tokens");
    }

    /// @notice After opening a perp hedge, subsequent deposits split P + N.
    ///
    /// @dev    Coverage = perpNotional / totalDeposited (wstETH units, oracle-free).
    ///         Open 5 wstETH perp on 10 wstETH TVL → 50% coverage → BOB gets 50% P, 50% N.
    function test_Deposit_WithPartialHedge_SplitsPAndN() public {
        // First deposit seeds the vault (genesis → 100% P).
        _deposit(ALICE, 10e18);

        // Open a 50% perp hedge: 5 wstETH notional on 10 wstETH TVL.
        adapter.openPosition(5e18);

        // Second deposit by BOB at ~50% coverage.
        _deposit(BOB, 10e18);

        uint256 bobShares = vault.balanceOf(BOB);
        uint256 bobP = pToken.balanceOf(BOB);
        uint256 bobN = nToken.balanceOf(BOB);

        assertEq(bobP + bobN, bobShares, "P + N invariant violated");
        assertGt(bobP, 0, "Expect some P at 50% coverage");
        assertGt(bobN, 0, "Expect some N at 50% coverage");
    }

    /* ///////////////////////////////////////////////////////////////
          2. TVL SHOCK → IntentRequested EVENT
    /////////////////////////////////////////////////////////////// */

    /// @notice A large TVL imbalance (perp notional far below vault TVL) triggers IntentRequested.
    ///
    /// @dev    Perp-model trigger:
    ///           deposited = 10 wstETH, perpNotional = 4 wstETH
    ///           imbalance = 6 wstETH = 60% of TVL >> 1% threshold
    ///           sizeDelta = deposited - notional = +6e18 (under-hedged, need more short)
    function test_RebalanceTriggerOnSizeImbalance() public {
        _deposit(ALICE, 10e18);

        // Open perp at only 40% of TVL → significant under-hedge.
        adapter.openPosition(4e18);

        // Expected: sizeDelta = 10e18 - 4e18 = +6e18 (positive = increase short).
        int256 expectedSizeDelta = 6e18;

        vm.expectEmit(true, false, false, true, address(vault));
        emit IVault.IntentRequested(expectedSizeDelta, block.timestamp);

        vault.checkAndEmitIntent();
    }

    /// @notice When perpNotional == totalDepositedAssets (≤1% drift), no event fires.
    ///
    /// @dev    deposited = 10 wstETH, perpNotional = 10 wstETH
    ///           imbalance = 0 ≤ threshold → silent.
    function test_NoIntentWithinThreshold() public {
        _deposit(ALICE, 10e18);

        // Perfectly sized perp: matches TVL exactly.
        adapter.openPosition(10e18);

        vm.recordLogs();
        vault.checkAndEmitIntent();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("IntentRequested(int256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                fail("IntentRequested must not fire within threshold");
            }
        }
    }

    /* ///////////////////////////////////////////////////////////////
          3. POSITIVE FUNDING → YIELD ACCUMULATOR
    /////////////////////////////////////////////////////////////// */

    /// @notice When funding is positive (longs pay shorts), accruedFunding() grows over time.
    ///         YieldAccumulator.snapshot() fails only when funding is negative and exceeds budget.
    function test_YieldAccumulatorWithPositiveFunding() public {
        _deposit(ALICE, 50e18);

        // Open a 50 wstETH perp position.
        adapter.openPosition(50e18);

        // Set a positive funding rate: vault earns.
        adapter.setMockFundingRate(1e12); // positive = longs pay shorts

        assertEq(adapter.accruedFunding(), 0, "No blocks elapsed yet");

        // Fast-forward 1,000 blocks.
        vm.roll(block.number + 1_000);

        int256 accrued = adapter.accruedFunding();
        assertGt(accrued, 0, "Positive funding must accrue over time");

        // Verify formula: fundingRate × blocks × notional / 1e18.
        int256 expectedFunding = int256(1e12) * int256(1_000) * int256(50e18) / 1e18;
        assertEq(accrued, expectedFunding);
    }

    /// @notice Negative funding: vault pays. snapshot() reverts if budget insufficient.
    function test_YieldAccumulatorNegativeFunding_RevertsWithoutBudget() public {
        _deposit(ALICE, 50e18);
        adapter.openPosition(50e18);

        // Set strongly negative funding: vault pays.
        adapter.setMockFundingRate(-1e15); // negative = vault pays

        vm.roll(block.number + 1_000);

        // No yield has accrued yet (FixedPricer returns constant rate → 0 delta).
        // Budget = 0 → negative funding reverts with InsufficientBudget.
        vm.expectRevert();
        yieldAccum.snapshot();
    }

    /* ///////////////////////////////////////////////////////////////
              4. REDEEM → P + N BURNED, wstETH RETURNED
    /////////////////////////////////////////////////////////////// */

    function test_RedeemBurnsTokensAndReturnsAssets() public {
        uint256 depositAmount = 10e18;
        _deposit(ALICE, depositAmount);

        uint256 shares = vault.balanceOf(ALICE);
        uint256 aliceP = pToken.balanceOf(ALICE);
        uint256 aliceN = nToken.balanceOf(ALICE);
        uint256 aliceWst = wstETH.balanceOf(ALICE);

        assertGt(shares, 0);
        assertEq(aliceP + aliceN, shares, "P + N must equal shares");

        // Standard redeem — uses greedy P-first computeMerge.
        vm.startPrank(ALICE);
        vault.approve(address(vault), shares);
        uint256 returned = vault.redeem(shares, ALICE, ALICE);
        vm.stopPrank();

        assertEq(pToken.balanceOf(ALICE), 0, "All P must be burned");
        assertEq(nToken.balanceOf(ALICE), 0, "All N must be burned");
        assertEq(vault.balanceOf(ALICE), 0, "All shares must be burned");
        assertApproxEqAbs(returned, depositAmount, 1, "Should return ~full deposit");
        assertApproxEqAbs(wstETH.balanceOf(ALICE), aliceWst + returned, 1);
    }

    /// @notice redeemTranched: a user who deposited at 0% coverage holds only N
    ///         and can redeem by explicitly specifying (0, shares) without needing P.
    function test_RedeemTranched_AllNPath() public {
        // Step 1: ALICE deposits first (genesis → all P, establishes non-zero totalDeposited).
        _deposit(ALICE, 5e18);
        assertGt(pToken.balanceOf(ALICE), 0, "ALICE: genesis should give P");

        // Step 2: No perp opened → adapter.totalHedgedNotional() = 0.
        //         Vault has totalDeposited > 0 → _currentCoverage() returns 0.

        // Step 3: BOB deposits second — coverage = 0 → all N tokens.
        _deposit(BOB, 5e18);

        uint256 shares = vault.balanceOf(BOB);
        assertEq(pToken.balanceOf(BOB), 0, "No P at 0% coverage");
        assertEq(nToken.balanceOf(BOB), shares, "All N at 0% coverage");

        // Step 4: BOB redeems via explicit all-N path.
        vm.startPrank(BOB);
        vault.approve(address(vault), shares);
        uint256 returned = vault.redeemTranched(shares, BOB, BOB, 0, shares);
        vm.stopPrank();

        assertEq(nToken.balanceOf(BOB), 0, "All N must be burned");
        assertGt(returned, 0, "Must receive wstETH");
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
}
