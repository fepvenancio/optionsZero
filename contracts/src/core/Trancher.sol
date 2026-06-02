// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ITrancher} from "../interfaces/ITrancher.sol";
import {IPerpAdapter} from "../hedge/IPerpAdapter.sol";
import {PToken} from "../tokens/PToken.sol";
import {NToken} from "../tokens/NToken.sol";
import {Constants} from "./Constants.sol";

/// @title  Trancher
/// @author OptionZero
/// @notice Manages the P/N tranche split for every deposit and redemption
///         that flows through Vault. Trancher is the sole minter/burner of
///         PToken and NToken.
///
/// @dev    Split formula (wstETH-denominated):
///
///           coverage  = min(1e18, perpHedgedNotional_wstETH / depositedCollateral_wstETH)
///           pAmount   = shares × coverage / 1e18
///           nAmount   = shares - pAmount
///
///         COVERAGE DENOMINATOR: uses vault.totalDepositedAssets() — NOT
///         totalAssets(). The distinction prevents flash-loan / donation attacks:
///         an attacker who donates wstETH directly to Vault inflates totalAssets()
///         but cannot touch totalDepositedAssets(), so the coverage ratio is
///         unaffected. See Fix 3 in the security audit.
///
///         Both the numerator (perpHedgedNotional from IPerpAdapter) and denominator
///         (totalDepositedAssets from Vault) are expressed in wstETH units, so no
///         oracle is required in the split path. This is a deliberate POC simplification.
///
///         Merge formula (burn on redemption):
///
///           pToBurn + nToBurn == shares   ← the ONLY invariant enforced
///
///         The caller (Vault) specifies the exact (pToBurn, nToBurn) split.
///         Two previously fatal flaws are eliminated by this design:
///
///         1. LOCKUP FLAW: Global-ratio merging forced users to hold a specific
///            P:N ratio matching the pool average, permanently locking capital
///            for anyone who deposited at a different coverage level. User-
///            specified ratios eliminate this entirely.
///
///         2. ROUNDING DRIFT: Independent floor-divisions on pBurned and nBurned
///            caused (burned total < shares), slowly diverging the P+N supply
///            from vault share supply. Using addition instead of division means
///            no rounding occurs and the invariant holds exactly.
contract Trancher is ITrancher {
    /* ///////////////////////////////////////////////////////////////
                                CONSTANTS
    /////////////////////////////////////////////////////////////// */

    /// @dev 18-decimal WAD unit. Imported from the shared Constants library
    ///      to prevent silent divergence if the value is ever changed.
    uint256 internal constant SCALE = Constants.SCALE;

    /* ///////////////////////////////////////////////////////////////
                            IMMUTABLE STATE
    /////////////////////////////////////////////////////////////// */

    /// @notice The Vault contract. Only this address may call split/merge.
    address public immutable vault;

    /// @notice The PToken contract this Trancher controls.
    PToken public immutable pToken;

    /// @notice The NToken contract this Trancher controls.
    NToken public immutable nToken;

    /// @notice Perp adapter — used to read aggregate hedged notional (wstETH units).
    IPerpAdapter public immutable perpAdapter;

    /* ///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    /////////////////////////////////////////////////////////////// */

    /// @param vault_       Address of Vault.
    /// @param pToken_      Address of the PToken ERC-20.
    /// @param nToken_      Address of the NToken ERC-20.
    /// @param perpAdapter_ Address of the IPerpAdapter.
    constructor(
        address vault_,
        address pToken_,
        address nToken_,
        address perpAdapter_,
        address /*pricer_*/ // retained for deployment ABI compatibility; unused in POC
    ) {
        vault = vault_;
        pToken = PToken(pToken_);
        nToken = NToken(nToken_);
        perpAdapter = IPerpAdapter(perpAdapter_);
    }

    /* ///////////////////////////////////////////////////////////////
                                MODIFIERS
    /////////////////////////////////////////////////////////////// */

    modifier onlyVault() {
        if (msg.sender != vault) revert Trancher_OnlyVault(msg.sender);
        _;
    }

    /* ///////////////////////////////////////////////////////////////
                         STATE-CHANGING FUNCTIONS
    /////////////////////////////////////////////////////////////// */

    /// @inheritdoc ITrancher
    function split(address receiver, uint256 shares)
        external
        override
        onlyVault
        returns (uint256 pMinted, uint256 nMinted)
    {
        if (shares == 0) revert Trancher_ZeroShares();

        uint256 coverage = _currentCoverage();

        pMinted = (shares * coverage) / SCALE;
        nMinted = shares - pMinted;

        if (pMinted > 0) pToken.mint(receiver, pMinted);
        if (nMinted > 0) nToken.mint(receiver, nMinted);

        emit Split(receiver, shares, pMinted, nMinted);
    }

    /// @inheritdoc ITrancher
    /// @dev Security: the ONLY invariant enforced is pToBurn + nToBurn == shares.
    ///      No global ratio is computed. No division is performed. This eliminates
    ///      both the lockup flaw and integer division rounding drift simultaneously.
    function merge(address owner, uint256 shares, uint256 pToBurn, uint256 nToBurn)
        external
        override
        onlyVault
        returns (uint256 pBurned, uint256 nBurned)
    {
        if (shares == 0) revert Trancher_ZeroShares();

        // The one and only constraint: amounts must sum to shares being redeemed.
        // This makes rounding drift mathematically impossible — no division involved.
        if (pToBurn + nToBurn != shares) {
            revert Trancher_InvalidMergeRatio(pToBurn, nToBurn, shares);
        }

        if (pToBurn > 0) {
            uint256 pBal = pToken.balanceOf(owner);
            if (pBal < pToBurn) revert Trancher_InsufficientPBalance(owner, pToBurn, pBal);
            pToken.burn(owner, pToBurn);
        }
        if (nToBurn > 0) {
            uint256 nBal = nToken.balanceOf(owner);
            if (nBal < nToBurn) revert Trancher_InsufficientNBalance(owner, nToBurn, nBal);
            nToken.burn(owner, nToBurn);
        }

        pBurned = pToBurn;
        nBurned = nToBurn;
        emit Merge(owner, shares, pBurned, nBurned);
    }

    /* ///////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////// */

    /// @inheritdoc ITrancher
    /// @dev Greedy P-first: uses as much of owner's P balance as possible,
    ///      then fills the remainder with N. Safe default because burning P
    ///      first reduces the stable-tranche obligation before touching N.
    function computeMerge(address owner, uint256 shares)
        external
        view
        override
        returns (uint256 pToBurn, uint256 nToBurn)
    {
        uint256 pBal = pToken.balanceOf(owner);
        pToBurn = pBal >= shares ? shares : pBal;
        nToBurn = shares - pToBurn;
        // Note: if nToken.balanceOf(owner) < nToBurn, merge() will revert with
        // Trancher_InsufficientNBalance. The user must then either acquire N
        // tokens on a secondary market or call redeemTranched() with the exact
        // ratio they hold.
    }

    /// @inheritdoc ITrancher
    function previewSplit(uint256 shares) external view override returns (uint256 pAmount, uint256 nAmount) {
        uint256 coverage = _currentCoverage();
        pAmount = (shares * coverage) / SCALE;
        nAmount = shares - pAmount;
    }

    /// @inheritdoc ITrancher
    /// @dev Called only by Vault.cancelRequest() to restore P/N tokens that were
    ///      burned during Phase 1 of the async exit. Does NOT consult the coverage
    ///      formula — the exact original amounts are minted back to preserve the
    ///      P+N == activeVaultSupply invariant without rounding side-effects.
    function splitExact(address receiver, uint256 pToMint, uint256 nToMint) external override onlyVault {
        if (pToMint > 0) pToken.mint(receiver, pToMint);
        if (nToMint > 0) nToken.mint(receiver, nToMint);
        emit Split(receiver, pToMint + nToMint, pToMint, nToMint);
    }

    /* ///////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    /////////////////////////////////////////////////////////////// */

    /// @dev Computes hedge coverage = min(1e18, perpHedgedNotional_wstETH / depositedCollateral_wstETH).
    ///      Returns 1e18 when the vault is empty (bootstrap: first depositor gets 100% P).
    ///
    ///      FLASH LOAN FIX: reads vault.totalDepositedAssets() instead of totalAssets().
    ///      totalDepositedAssets() is updated only by formal deposit/withdraw hooks.
    ///      A direct wstETH donation to the vault address cannot inflate it, making
    ///      coverage manipulation via flash loan + donate attack impossible.
    ///
    ///      ORACLE-FREE: both numerator and denominator are wstETH units, so no
    ///      price feed is needed in the split path.
    function _currentCoverage() internal view returns (uint256 coverage) {
        uint256 deposited = _vaultDepositedAssets(); // wstETH (1e18), flash-loan resistant

        if (deposited == 0) {
            // Empty vault: bootstrap at 100% so the first depositor receives
            // only P tokens (fully stable at genesis).
            return SCALE;
        }

        uint256 hedgedNotional = _hedgedNotionalWstETH();

        coverage = hedgedNotional >= deposited ? SCALE : (hedgedNotional * SCALE) / deposited;
    }

    /// @dev Reads the total hedged notional (wstETH units) from the perp adapter.
    ///      Uses a low-level staticcall so this works with any adapter exposing the selector.
    function _hedgedNotionalWstETH() internal view returns (uint256 total) {
        (bool ok, bytes memory data) = address(perpAdapter).staticcall(abi.encodeWithSignature("totalHedgedNotional()"));
        if (ok && data.length >= 32) {
            total = abi.decode(data, (uint256));
        }
    }

    /// @dev Flash-loan-resistant deposited balance from vault.
    ///      Calls totalDepositedAssets() — updated only via deposit/withdraw hooks,
    ///      never by raw token transfers to the vault address.
    function _vaultDepositedAssets() internal view returns (uint256) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("totalDepositedAssets()"));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// @dev Low-level totalSupply read from vault (ERC-20 shares).
    ///      Retained for potential future use (e.g. slippage guards).
    function _vaultTotalSupply() internal view returns (uint256) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
