// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  ITrancher
/// @notice Interface for the OptionZero tranche splitter.
///         Trancher mints/burns PToken and NToken in proportion to the vault's
///         current hedge coverage whenever assets flow in or out of Vault.
interface ITrancher {
    /* ///////////////////////////////////////////////////////////////
                                  ERRORS
    /////////////////////////////////////////////////////////////// */

    error Trancher_OnlyVault(address caller);
    error Trancher_ZeroShares();
    error Trancher_InsufficientPBalance(address from, uint256 required, uint256 available);
    error Trancher_InsufficientNBalance(address from, uint256 required, uint256 available);

    /// @dev Reverts when pToBurn + nToBurn != shares in merge().
    ///      This is the invariant that eliminates rounding drift:
    ///      no division is ever performed, so burned total always equals shares.
    error Trancher_InvalidMergeRatio(uint256 pToBurn, uint256 nToBurn, uint256 shares);

    /* ///////////////////////////////////////////////////////////////
                                  EVENTS
    /////////////////////////////////////////////////////////////// */

    /// @notice Emitted on every successful split (deposit flow).
    event Split(address indexed receiver, uint256 shares, uint256 pMinted, uint256 nMinted);

    /// @notice Emitted on every successful merge (redemption flow).
    event Merge(address indexed from, uint256 shares, uint256 pBurned, uint256 nBurned);

    /* ///////////////////////////////////////////////////////////////
                           STATE-CHANGING FUNCTIONS
    /////////////////////////////////////////////////////////////// */

    /// @notice Called by Vault after minting `shares` to `receiver`.
    ///         Mints proportional PToken + NToken based on current hedge coverage.
    /// @param  receiver Address to receive the minted tokens.
    /// @param  shares   ERC-4626 vault shares just minted.
    /// @return pMinted  PTokens minted.
    /// @return nMinted  NTokens minted.
    function split(address receiver, uint256 shares) external returns (uint256 pMinted, uint256 nMinted);

    /// @notice Called by Vault before burning `shares` from `owner`.
    ///         Burns a caller-specified combination of PToken + NToken.
    ///
    /// @dev    SECURITY: The caller specifies the exact (pToBurn, nToBurn) split.
    ///         The only invariant enforced here is:
    ///
    ///           pToBurn + nToBurn == shares
    ///
    ///         This design eliminates two critical flaws from a global-ratio approach:
    ///
    ///         1. LOCKUP FLAW: A user who deposited at 100% coverage holds only P
    ///            tokens. If coverage later drifts, a global-ratio merge would
    ///            demand N tokens they don't own, permanently locking their capital.
    ///            With user-specified ratios, they simply pass (shares, 0) and redeem
    ///            using only their P tokens.
    ///
    ///         2. ROUNDING DRIFT: Two independent floor-divisions on pBurned and
    ///            nBurned cause total burned < shares over many redemptions, slowly
    ///            breaking the P + N == vaultShares invariant. Using addition
    ///            (pToBurn + nToBurn == shares) instead of division eliminates drift
    ///            entirely — no fractional arithmetic is performed.
    ///
    /// @param  owner    Address whose tokens will be burned.
    /// @param  shares   ERC-4626 vault shares about to be redeemed.
    /// @param  pToBurn  PTokens to burn from owner.
    /// @param  nToBurn  NTokens to burn from owner.
    /// @return pBurned  PTokens actually burned (== pToBurn).
    /// @return nBurned  NTokens actually burned (== nToBurn).
    function merge(address owner, uint256 shares, uint256 pToBurn, uint256 nToBurn)
        external
        returns (uint256 pBurned, uint256 nBurned);

    /* ///////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////// */

    /// @notice Compute a greedy P-first merge ratio for `owner` redeeming `shares`.
    ///         Uses as much of owner's P balance as possible, then fills the
    ///         remainder with N. Used by Vault's standard redeem() path.
    ///
    /// @dev    Greedy P-first is a safe default because P is the stable tranche;
    ///         burning P first reduces the protocol's USD-denominated obligations
    ///         before touching the riskier N supply.
    ///
    ///         If owner's combined P + N balance < shares, the returned nToBurn will
    ///         exceed the owner's N balance and merge() will revert — the user must
    ///         acquire tokens on secondary markets or use redeemTranched() with a
    ///         ratio they actually hold.
    ///
    /// @param  owner   Address of the redeemer.
    /// @param  shares  Vault shares being redeemed.
    /// @return pToBurn Suggested P tokens to burn.
    /// @return nToBurn Suggested N tokens to burn.
    function computeMerge(address owner, uint256 shares) external view returns (uint256 pToBurn, uint256 nToBurn);

    /// @notice Preview how many P and N tokens correspond to `shares` at the
    ///         current hedge coverage ratio. Used by the frontend and tests.
    /// @param  shares   Vault shares to preview.
    /// @return pAmount  Expected PTokens.
    /// @return nAmount  Expected NTokens.
    function previewSplit(uint256 shares) external view returns (uint256 pAmount, uint256 nAmount);

    /// @notice Mint exact P and N amounts back to a user — used exclusively by
    ///         `Vault.cancelRequest()` to restore tokens burned in Phase 1.
    ///
    /// @dev    Restricted to vault. Does NOT go through the coverage formula —
    ///         the amounts are the exact values that were burned at request time,
    ///         so the protocol-level P+N == activeSupply invariant is preserved.
    ///
    /// @param  receiver  Address to receive the re-minted tokens.
    /// @param  pToMint   PTokens to mint (== pBurned from the cancelled request).
    /// @param  nToMint   NTokens to mint (== nBurned from the cancelled request).
    function splitExact(address receiver, uint256 pToMint, uint256 nToMint) external;
}
