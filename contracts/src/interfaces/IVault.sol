// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITrancher} from "./ITrancher.sol";
import {BatchTypes} from "../core/BatchTypes.sol";

/// @title  IVault
/// @notice External interface for the OptionZero ERC-4626 vault.
///         Consumers (Trancher, daemon event listeners, integrators) depend
///         only on this interface — never on the concrete Vault implementation.
interface IVault {
    /* //////////////////////////////////////////////////////////////
                               ERRORS
    ////////////////////////////////////////////////////////////// */

    // --- Legacy errors (ERC-4626 and perp trigger) ---
    error Vault_ZeroAssets();
    error Vault_BelowMinDeposit(uint256 minDeposit);
    error Vault_AdapterNotSet();
    error Vault_Paused();

    // --- Access control errors ---

    /// @dev Revert when a caller is not the contract owner.
    error Vault_OnlyOwner(address caller);

    /// @dev Revert when a zero address is provided where a non-zero address is required.
    error Vault_ZeroAddress();

    // --- Slippage errors ---

    /// @dev Revert when a deposit or redeem result is below the caller's minimum.
    /// @param got  Actual value produced.
    /// @param min  Minimum the caller would accept.
    error Vault_SlippageExceeded(uint256 got, uint256 min);

    // --- Batch lifecycle errors ---

    /// @dev Revert when a batch ID that does not exist is referenced.
    error Vault_BatchNotFound(bytes32 batchId);

    /// @dev Revert when closeBatch() is called on an already-closed batch.
    error Vault_BatchAlreadyClosed(bytes32 batchId);

    /// @dev Revert when settleBatch() is called on a batch that has not been closed yet.
    error Vault_BatchNotClosed(bytes32 batchId);

    /// @dev Revert when settleBatch() is called on an already-settled batch.
    error Vault_BatchAlreadySettled(bytes32 batchId);

    /// @dev Revert when claimRedeemedAssets() is called before the batch is settled.
    error Vault_BatchNotSettled(bytes32 batchId);

    /// @dev Revert when a requestId does not map to an existing request.
    error Vault_RequestNotFound(bytes32 requestId);

    /// @dev Revert when a request is not in PENDING state (already claimed, cancelled, undefined).
    error Vault_RequestNotPending(bytes32 requestId);

    /// @dev Revert when the caller of claimRedeemedAssets() is not the original requester.
    error Vault_NotRequestOwner(address caller, address owner);

    /// @dev Revert when settleBatch() provides zero assets (nothing was bridged).
    error Vault_ZeroAssetsReturned();

    /// @dev Revert when the settler address has not been configured.
    error Vault_SettlerNotSet();

    /// @dev Revert when a restricted function is called by a non-settler address.
    error Vault_OnlySettler(address caller);

    /// @dev Revert when cancelRequest() is called on a request that is not PENDING.
    error Vault_RequestNotCancellable(bytes32 requestId);

    /// @dev Revert when cancelRequest() is called after the batch has been closed.
    ///      Once the daemon has started the cross-chain unwind, cancellation is impossible.
    error Vault_CannotCancelClosedBatch(bytes32 batchId);

    /* //////////////////////////////////////////////////////////////
                               EVENTS
    ////////////////////////////////////////////////////////////// */

    // --- Legacy events ---

    /// @notice Emitted when the daemon should submit a perp resize intent.
    /// @param  deltaDeviation  Signed size delta (wstETH units, 1e18).
    ///                         Positive = vault under-hedged (need more short notional).
    ///                         Negative = vault over-hedged (need to reduce short notional).
    /// @param  timestamp       Block timestamp of the trigger.
    event IntentRequested(int256 indexed deltaDeviation, uint256 timestamp);

    /// @notice Emitted when the perp adapter address is updated.
    event OptionAdapterUpdated(address indexed newAdapter);

    // --- Access control events ---

    /// @notice Emitted when contract ownership is transferred.
    /// @param  previousOwner The address that held ownership.
    /// @param  newOwner      The address that now holds ownership.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the settler address is configured.
    /// @param  settler The new settler address.
    event SettlerSet(address indexed settler);

    // --- Batch lifecycle events ---

    /// @notice Emitted when a new redemption batch is opened.
    /// @param  batchId       The new batch identifier.
    /// @param  openedAtBlock Block number when the batch was opened.
    event BatchOpened(bytes32 indexed batchId, uint64 openedAtBlock);

    /// @notice Emitted when a user submits an async redemption request.
    /// @param  requestId     Unique identifier for the request.
    /// @param  batchId       The batch this request was placed into.
    /// @param  user          Address that submitted the request (and must claim).
    /// @param  receiver      Address that will receive wstETH on claim.
    /// @param  shares        Vault shares locked.
    /// @param  pBurned       PTokens burned immediately.
    /// @param  nBurned       NTokens burned immediately.
    /// @param  assetsLocked  convertToAssets(shares) at request block — pro-rata weight.
    event RedemptionRequested(
        bytes32 indexed requestId,
        bytes32 indexed batchId,
        address indexed user,
        address receiver,
        uint128 shares,
        uint128 pBurned,
        uint128 nBurned,
        uint128 assetsLocked
    );

    /// @notice Emitted when a user cancels a PENDING request before its batch is closed.
    /// @param  requestId  The cancelled request identifier.
    /// @param  user       The requester whose shares and P/N tokens were restored.
    /// @param  shares     Vault shares returned to user.
    event RequestCancelled(bytes32 indexed requestId, address indexed user, uint128 shares);

    /// @notice Emitted when the daemon closes the current batch.
    /// @param  batchId            The closed batch identifier.
    /// @param  totalSharesQueued  Total vault shares in this batch.
    /// @param  totalAssetsLocked  Total pro-rata weight (sum of assetsLocked).
    event BatchClosed(bytes32 indexed batchId, uint128 totalSharesQueued, uint128 totalAssetsLocked);

    /// @notice Emitted when the daemon settles a batch with bridged wstETH.
    /// @param  batchId        The settled batch identifier.
    /// @param  assetsReturned Actual wstETH received from the bridge.
    event BatchSettled(bytes32 indexed batchId, uint128 assetsReturned);

    /// @notice Emitted when a user successfully claims their redeemed wstETH.
    /// @param  requestId  The request identifier.
    /// @param  user       The original requester.
    /// @param  receiver   The wstETH recipient.
    /// @param  assets     Amount of wstETH transferred.
    event AssetsClaimed(bytes32 indexed requestId, address indexed user, address receiver, uint128 assets);

    /* //////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @notice Total wstETH held by the vault (ERC-4626 totalAssets).
    ///         Reflects the true underlying including yield. NOT flash-loan resistant.
    function totalAssets() external view returns (uint256);

    /// @notice Flash-loan-resistant deposited balance.
    ///         Updated only by formal deposit()/mint()/redeem()/withdraw() calls.
    function totalDepositedAssets() external view returns (uint256);

    /// @notice Hedge coverage ratio: perpNotional / totalDepositedAssets, 18 decimals.
    function hedgeCoverage() external view returns (uint256);

    /// @notice The identifier of the currently-open batch accepting new requests.
    function currentBatchId() external view returns (bytes32);

    /// @notice Total vault shares that are queued for async redemption (not yet settled).
    ///         These shares are locked in the vault contract; they do NOT reduce totalSupply
    ///         until settleBatch() burns them. Share price is therefore slightly diluted
    ///         during the pending window — this is an intentional trade-off.
    function totalPendingRedemption() external view returns (uint128);

    /// @notice Read a full BatchInfo by batchId.
    function getBatch(bytes32 batchId) external view returns (BatchTypes.BatchInfo memory);

    /// @notice Read a full RedemptionRequest by requestId.
    function getRequest(bytes32 requestId) external view returns (BatchTypes.RedemptionRequest memory);

    /* //////////////////////////////////////////////////////////////
                       STATE-CHANGING FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    // --- Perp trigger (unchanged) ---

    /// @notice Callable by the daemon to emit IntentRequested when perp is imbalanced.
    function checkAndEmitIntent() external;

    // --- Ownership ---

    /// @notice Transfer ownership of the vault to `newOwner`.
    /// @dev    Only callable by the current owner. Emits OwnershipTransferred.
    ///         Used to hand off admin key to a multisig after initial deployment.
    /// @param  newOwner  Address of the new owner. Must be non-zero.
    function transferOwnership(address newOwner) external;

    /// @notice Configure the privileged settler address.
    ///
    /// @dev    Only callable by the owner (Fix 2). In production, the owner should
    ///         be a multisig or timelock before calling this on mainnet.
    ///
    /// @param  settler_  Address of the daemon EOA or multisig that controls batch flow.
    function setSettler(address settler_) external;

    // --- Batch lifecycle ---

    /// @notice Deposit `assets` wstETH with a minimum shares slippage guard.
    ///
    /// @dev    ERC-4626-compliant overload. Pass `minShares = 0` to disable the guard
    ///         (equivalent to the standard 2-arg deposit).
    ///
    /// @param  assets     Amount of wstETH to deposit.
    /// @param  receiver   Address to receive shares, PTokens, and NTokens.
    /// @param  minShares  Minimum vault shares acceptable. Reverts if below.
    /// @return shares     Vault shares minted.
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);

    /// @notice Submit an async redemption request.
    ///
    /// @dev    Phase 1 of the async exit lifecycle.
    ///         P and N tokens are burned immediately at the current coverage ratio.
    ///         Vault shares are transferred from `owner` to the vault contract (locked).
    ///         The pro-rata assets value (`assetsLocked`) is snapshotted at this block.
    ///
    ///         When `owner != msg.sender`, the vault must have been approved to spend
    ///         the owner's vault shares (ERC-20 allowance). This is enforced via
    ///         `_spendAllowance` — Solady's internal `_transfer` alone does not check it.
    ///
    /// @param  shares          Vault shares to redeem.
    /// @param  receiver        Address to receive wstETH on claim.
    /// @param  owner           Address whose shares and P/N tokens are consumed.
    /// @param  pToBurn         Exact PTokens to burn (use 0 if caller holds only N).
    /// @param  nToBurn         Exact NTokens to burn (use 0 if caller holds only P).
    /// @param  minAssetsLocked Minimum assetsLocked acceptable. Pass 0 to disable.
    /// @return requestId       Unique identifier for the request.
    function requestRedeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 pToBurn,
        uint256 nToBurn,
        uint128 minAssetsLocked
    ) external returns (bytes32 requestId);

    /// @notice Convenience wrapper for requestRedeem using an asset amount.
    ///         Computes shares via previewWithdraw and P/N split via computeMerge.
    /// @param  assets    wstETH equivalent to redeem.
    /// @param  receiver  Address to receive wstETH on claim.
    /// @param  owner     Address whose shares and P/N tokens are consumed.
    /// @return requestId Unique identifier for the request.
    function requestWithdraw(uint256 assets, address receiver, address owner) external returns (bytes32 requestId);

    /// @notice Cancel a PENDING request before its batch has been closed.
    ///
    /// @dev    Only the original requester (`request.user`) may cancel.
    ///         Cancellation is only possible while the batch is still OPEN.
    ///         Once the daemon closes the batch (signals the cross-chain unwind has started),
    ///         cancellation is permanently disabled for that batch.
    ///
    ///         Effects (all reversed):
    ///           - Vault shares returned from vault → user.
    ///           - P and N tokens re-minted to user (exact amounts burned at request time).
    ///           - Batch accounting decremented (totalSharesQueued, totalAssetsLocked).
    ///           - Request status set to CANCELLED.
    ///
    /// @param  requestId  The request to cancel.
    function cancelRequest(bytes32 requestId) external;

    /// @notice Close the currently-open batch and open a new one.
    ///
    /// @dev    Only callable by the settler address. After closure, no new requests
    ///         can join this batch. The daemon then resizes the perp on Hyperliquid,
    ///         bridges wstETH, and calls settleBatch().
    ///
    /// @return closedBatchId  The ID of the batch that was just closed.
    /// @return newBatchId     The ID of the freshly opened batch.
    function closeBatch() external returns (bytes32 closedBatchId, bytes32 newBatchId);

    /// @notice Settle a closed batch with bridged wstETH from Hyperliquid.
    ///
    /// @dev    Only callable by the settler address. Phase 2 of the lifecycle.
    ///         The settler MUST have approved this contract for `assetsReturned` wstETH
    ///         before calling (pull model via safeTransferFrom).
    ///         After settlement all requestors in the batch may call claimRedeemedAssets().
    ///
    /// @param  batchId        The closed batch to settle.
    /// @param  assetsReturned Actual wstETH received from the Hyperliquid bridge.
    function settleBatch(bytes32 batchId, uint128 assetsReturned) external;

    /// @notice Claim pro-rata wstETH from a settled batch.
    ///
    /// @dev    Phase 3 of the lifecycle. Caller must be request.user.
    ///         Formula: userClaim = assetsReturned * assetsLocked / totalAssetsLocked.
    ///
    /// @param  requestId  The request to claim against.
    /// @return assets     wstETH transferred to request.receiver.
    function claimRedeemedAssets(bytes32 requestId) external returns (uint256 assets);
}
