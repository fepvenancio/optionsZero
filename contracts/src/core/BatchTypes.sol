// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title  BatchTypes
/// @notice Shared data types for the OptionZero async redemption batch lifecycle.
///
///         Lifecycle state machine:
///           PENDING   — request is live; user's vault shares locked, P/N burned.
///           CLAIMED   — batch settled, user has received their wstETH. Terminal.
///           CANCELLED — user cancelled before the batch was closed. Terminal.
///                       Shares returned to user; P/N tokens re-minted.
///
///         The batch itself transitions through two boolean flags:
///           !isClosed, !isSettled → OPEN   : accepts new requests
///            isClosed, !isSettled → CLOSED : no new requests; awaiting keeper settlement
///            isClosed,  isSettled → SETTLED: users may claim
library BatchTypes {
    /* //////////////////////////////////////////////////////////////
                           REQUEST STATUS
    ////////////////////////////////////////////////////////////// */

    /// @notice Lifecycle state of a single redemption request.
    enum RequestStatus {
        /// @dev Zero-initialized sentinel. Distinguishes "does not exist" from "in-flight".
        UNDEFINED,
        /// @dev Request is live. Shares locked, P/N burned, assets not yet distributed.
        PENDING,
        /// @dev User has successfully claimed their wstETH. Terminal state.
        CLAIMED,
        /// @dev User cancelled before the batch was closed. Shares + P/N restored. Terminal.
        CANCELLED
    }

    /* //////////////////////////////////////////////////////////////
                          REDEMPTION REQUEST
    ////////////////////////////////////////////////////////////// */

    /// @notice One user's async redemption request, stored by requestId.
    ///
    /// @dev    Exchange rate is snapshotted at **request time** (not settlement time).
    ///         This prevents wstETH yield that accrues during the async bridge window
    ///         from benefiting exiting users at the expense of remaining depositors.
    ///
    ///         `assetsLocked` is computed as `convertToAssets(shares)` at the moment
    ///         `requestRedeem()` is called and used as the denominator-free pro-rata
    ///         weight within the batch (avoids a second oracle call at claim time).
    struct RedemptionRequest {
        /// @dev Address that submitted the request and is the only valid claimer.
        address user;
        /// @dev Address that receives wstETH on `claimRedeemedAssets()`.
        address receiver;
        /// @dev Batch this request belongs to.
        bytes32 batchId;
        /// @dev Vault shares locked at request time (not yet burned — burned at settlement).
        uint128 shares;
        /// @dev PTokens burned at request time (captured for event emission / analytics).
        uint128 pBurned;
        /// @dev NTokens burned at request time (captured for event emission / analytics).
        uint128 nBurned;
        /// @dev convertToAssets(shares) at request block. Used for pro-rata claim math.
        ///      This is the user's "slot" in the batch's pool of claimable assets.
        uint128 assetsLocked;
        /// @dev Block timestamp when the request was created.
        uint64 requestTimestamp;
        /// @dev Current lifecycle state.
        RequestStatus status;
    }

    /* //////////////////////////////////////////////////////////////
                              BATCH INFO
    ////////////////////////////////////////////////////////////// */

    /// @notice Aggregate state for one redemption batch.
    ///
    /// @dev    One batch collects requests over a time window (BATCH_WINDOW_BLOCKS).
    ///         The keeper closes the batch, resizes the perp on Hyperliquid, bridges
    ///         wstETH back, and calls `settleBatch(batchId, assetsReturned)`.
    ///
    ///         Pro-rata claim formula:
    ///           userClaim = assetsReturned × request.assetsLocked / totalAssetsLocked
    ///
    ///         If `assetsReturned < totalAssetsLocked` (slippage / fees on the bridge),
    ///         all users in the batch share the shortfall proportionally.
    struct BatchInfo {
        /// @dev True once the keeper calls `closeBatch()`. No new requests accepted.
        bool isClosed;
        /// @dev True once `settleBatch()` is called with bridged wstETH. Claims unlock.
        bool isSettled;
        /// @dev Block number when the batch was opened (i.e. when the previous was closed).
        uint64 openedAtBlock;
        /// @dev Cumulative vault shares across all requests in this batch.
        uint128 totalSharesQueued;
        /// @dev Cumulative `assetsLocked` across all requests — the denominator for pro-rata.
        uint128 totalAssetsLocked;
        /// @dev Actual wstETH received from the bridge; written by `settleBatch()`.
        uint128 assetsReturned;
        /// @dev Running total of assets already claimed (invariant: claimedAssets <= assetsReturned).
        uint128 claimedAssets;
    }
}
