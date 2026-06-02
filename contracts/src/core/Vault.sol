// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ITrancher} from "../interfaces/ITrancher.sol";
import {IPerpAdapter} from "../hedge/IPerpAdapter.sol";
import {BatchTypes} from "./BatchTypes.sol";
import {Constants} from "./Constants.sol";

/// @title  Vault — OptionZero ERC-4626 Vault
/// @author OptionZero
/// @notice The primary entry point for the OptionZero protocol. Accepts wstETH
///         deposits, issues ERC-4626 vault shares, and triggers the Trancher
///         to mint/burn the P and N derivative tokens that represent each
///         depositor's tranched economic exposure.
///
/// @dev    Architecture notes:
///
///         1. UNDERLYING ASSET: wstETH (non-rebasing). The vault's totalAssets()
///            grows as the wstETH/stETH exchange rate increases — this is how
///            liquid staking yield accrues without any explicit compound call.
///
///         2. ERC-4626 INFLATION ATTACK: Solady's ERC4626 uses a virtual-offset
///            pattern (_decimalsOffset = 0 by default) that prevents donation
///            attacks by keeping a non-zero virtual supply. See Solady docs.
///
///         3. P/N MINTING: On every deposit, Trancher.split() is called inside
///            the overridden deposit() to mint P and N tokens to the receiver in
///            proportion to the current perp coverage. On every atomic redemption,
///            Trancher.merge() burns proportional P and N before the underlying
///            is released.
///
///         4. REBALANCE TRIGGER: Any address (intended to be the keeper) can
///            call checkAndEmitIntent() to compare totalDepositedAssets() against
///            the perp adapter's totalHedgedNotional() and emit IntentRequested
///            when the size imbalance exceeds IMBALANCE_THRESHOLD_BPS (1%).
///
///         5. ASYNC BATCH EXIT LIFECYCLE (KAM pattern):
///            requestRedeem()     — Phase 1: locks shares, burns P/N immediately,
///                                  snapshots exchange rate, queues into current batch.
///            cancelRequest()     — Phase 1 reversal: restores shares + P/N to user,
///                                  only valid while the batch is still open.
///            closeBatch()        — Settler-only: closes the batch, opens the next one.
///            settleBatch()       — Settler-only: receives bridged wstETH, unlocks claims.
///            claimRedeemedAssets() — User: claims pro-rata wstETH from settled batch.
///
///         6. OWNERSHIP / ACCESS CONTROL:
///            The deployer is the initial owner (stored in VaultStorage.owner).
///            Only the owner can call setSettler() or transferOwnership().
///            The settler can call closeBatch() and settleBatch().
///            This eliminates the unrestricted setSettler vulnerability.
///
/// @custom:storage-location erc7201:optionszero.storage.kvault
contract Vault is ERC4626, IVault {
    /* //////////////////////////////////////////////////////////////
                                CONSTANTS
    ////////////////////////////////////////////////////////////// */

    /// @notice WAD (18-decimal fixed-point unit). Sourced from the shared Constants
    ///         library to guarantee consistency with Trancher.
    uint256 public constant SCALE = Constants.SCALE;

    /// @notice Size imbalance threshold above which a perp resize is required.
    /// @dev    100 bps = 1% of TVL.
    uint256 public constant IMBALANCE_THRESHOLD_BPS = 100;

    /* //////////////////////////////////////////////////////////////
                             ERC-7201 STORAGE
    ////////////////////////////////////////////////////////////// */

    /// @custom:storage-location erc7201:optionszero.storage.kvault
    struct VaultStorage {
        // --- Core ERC-4626 state ---

        /// @dev wstETH token address (underlying asset).
        address asset;
        /// @dev Trancher contract — mints/burns P and N tokens.
        address trancher;
        /// @dev Active perp adapter — reads funding and manages short perp positions.
        address optionAdapter;
        /// @dev Flash-loan-resistant deposit tracker.
        ///      Incremented by deposit()/mint(); decremented by atomic redeem()/withdraw().
        ///      NOT decremented by requestRedeem() — decremented by settleBatch() instead.
        uint256 totalDeposited;

        // --- Access control ---

        /// @dev Contract owner. Set to deployer in constructor. May be transferred via
        ///      transferOwnership(). Controls setSettler() — the single privileged mutator.
        address owner;

        /// @dev Privileged address that can call closeBatch() and settleBatch().
        ///      In production: multisig or NEAR MPC key. In POC: keeper EOA.
        address settler;

        // --- Batch lifecycle state ---

        /// @dev The currently-open batch ID. All new requests go here.
        bytes32 currentBatchId;
        /// @dev Monotonic batch counter — nonce seed for deterministic batchId generation.
        uint256 batchCounter;
        /// @dev Monotonic request counter — nonce seed for deterministic requestId generation.
        uint256 requestCounter;
        /// @dev Shares locked in pending batches. These shares count in totalSupply()
        ///      (share price diluted) but not in totalAssets() (no double-counting).
        uint128 totalPendingRedemption;

        /// @dev Per-batch aggregate state.
        mapping(bytes32 => BatchTypes.BatchInfo) batches;
        /// @dev Per-request state.
        mapping(bytes32 => BatchTypes.RedemptionRequest) requests;
    }

    /// @dev Slot: keccak256(abi.encode(uint256(keccak256("optionszero.storage.kvault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _VAULT_STORAGE_LOCATION =
        0xb94f5374fce5edbc8e2a8697c15331677e6ebf0b000000000000000000000000;

    function _getVaultStorage() private pure returns (VaultStorage storage $) {
        assembly {
            $.slot := _VAULT_STORAGE_LOCATION
        }
    }

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    /// @param asset_         wstETH token address.
    /// @param trancher_      Trancher contract address.
    /// @param optionAdapter_ IPerpAdapter implementation address.
    constructor(address asset_, address trancher_, address optionAdapter_) {
        VaultStorage storage $ = _getVaultStorage();
        $.asset = asset_;
        $.trancher = trancher_;
        $.optionAdapter = optionAdapter_;

        // Fix 2: deployer becomes the initial owner.
        $.owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        // Open the genesis batch immediately on deployment.
        _openNewBatch($);
    }

    /* //////////////////////////////////////////////////////////////
                         ERC-4626 OVERRIDES
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc ERC4626
    function asset() public view override returns (address) {
        return _getVaultStorage().asset;
    }

    /// @inheritdoc ERC4626
    /// @dev wstETH balance held by this contract. LST yield accrues as the
    ///      wstETH/stETH rate increases — no explicit compound needed.
    ///      NOTE: Do NOT use this value as the flash-loan-resistant coverage
    ///      denominator in Trancher. Use totalDepositedAssets() instead.
    function totalAssets() public view override(ERC4626, IVault) returns (uint256) {
        return SafeTransferLib.balanceOf(_getVaultStorage().asset, address(this));
    }

    /// @notice Flash-loan-resistant total deposited tracker.
    ///         Unlike totalAssets(), this cannot be inflated by direct wstETH
    ///         donations to the vault address. Trancher's coverage denominator
    ///         MUST read this value, not totalAssets().
    function totalDepositedAssets() external view override returns (uint256) {
        return _getVaultStorage().totalDeposited;
    }

    function name() public pure override returns (string memory) {
        return "OptionZero Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "ozVault";
    }

    /* //////////////////////////////////////////////////////////////
                        DEPOSIT / MINT HOOKS
    ////////////////////////////////////////////////////////////// */

    /// @dev Called by Solady's ERC4626 after shares are minted to `to`.
    ///      Intentionally empty — P/N minting is handled in our overridden deposit().
    function _afterDeposit(
        uint256,
        /*assets*/
        uint256 /*shares*/
    )
        internal
        override
    {}

    /* //////////////////////////////////////////////////////////////
                      OVERRIDDEN ENTRY POINTS (atomic)
    ////////////////////////////////////////////////////////////// */

    /// @notice Deposit `assets` wstETH and receive vault shares + P and N tokens.
    /// @param  assets   Amount of wstETH to deposit (1e18).
    /// @param  receiver Address to receive shares, PTokens, and NTokens.
    /// @return shares   ERC-4626 vault shares minted.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        return deposit(assets, receiver, 0);
    }

    /// @notice Deposit with a minimum-shares slippage guard (Fix 4).
    /// @param  assets     wstETH to deposit.
    /// @param  receiver   Address to receive shares, PTokens, and NTokens.
    /// @param  minShares  Minimum acceptable vault shares. Pass 0 to disable.
    /// @return shares     Vault shares minted.
    function deposit(uint256 assets, address receiver, uint256 minShares) public override returns (uint256 shares) {
        if (assets == 0) revert Vault_ZeroAssets();
        shares = super.deposit(assets, receiver);

        // Fix 4: slippage guard — reverts if fewer shares than caller expected.
        if (minShares > 0 && shares < minShares) {
            revert Vault_SlippageExceeded(shares, minShares);
        }

        VaultStorage storage $ = _getVaultStorage();
        // split() is called BEFORE updating totalDeposited.
        // _currentCoverage() reads totalDepositedAssets(); if this is the first
        // deposit and totalDeposited is still 0, the genesis bootstrap fires
        // and the depositor receives 100% P tokens (fully stable entry).
        ITrancher($.trancher).split(receiver, shares);
        $.totalDeposited += assets;
    }

    /// @notice Mint `shares` vault shares by depositing the required wstETH.
    ///         Also mints proportional P and N tokens to `receiver`.
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        VaultStorage storage $ = _getVaultStorage();
        ITrancher($.trancher).split(receiver, shares);
        $.totalDeposited += assets;
    }

    /// @notice Atomic redeem — immediately burns P+N and returns wstETH.
    ///
    /// @dev    Appropriate when the vault's perp headroom allows instant exits.
    ///         For large exits requiring perp resizing, use requestRedeem() instead.
    ///
    /// @param  shares   Vault shares to redeem.
    /// @param  receiver Address to receive wstETH.
    /// @param  owner    Address whose shares and P/N tokens are burned.
    /// @return assets   wstETH returned to receiver.
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        VaultStorage storage $ = _getVaultStorage();
        (uint256 pToBurn, uint256 nToBurn) = ITrancher($.trancher).computeMerge(owner, shares);
        ITrancher($.trancher).merge(owner, shares, pToBurn, nToBurn);
        assets = super.redeem(shares, receiver, owner);
        $.totalDeposited = $.totalDeposited > assets ? $.totalDeposited - assets : 0;
    }

    /// @notice Atomic withdraw — immediately burns P+N and returns exact `assets` wstETH.
    ///         Merge ratio computed automatically (greedy P-first).
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        VaultStorage storage $ = _getVaultStorage();
        (uint256 pToBurn, uint256 nToBurn) = ITrancher($.trancher).computeMerge(owner, shares);
        ITrancher($.trancher).merge(owner, shares, pToBurn, nToBurn);
        super.withdraw(assets, receiver, owner);
        $.totalDeposited = $.totalDeposited > assets ? $.totalDeposited - assets : 0;
    }

    /// @notice Advanced atomic redemption — caller specifies exact P and N amounts.
    ///
    /// @dev    Required when the caller's tranche composition differs from the
    ///         greedy P-first default (e.g. a user who sold all their P tokens
    ///         on secondary markets and holds only N).
    ///
    /// @param  shares    Vault shares to burn.
    /// @param  receiver  Address to receive wstETH.
    /// @param  owner     Address whose shares and P/N tokens are burned.
    /// @param  pToBurn   Exact PTokens to burn from owner.
    /// @param  nToBurn   Exact NTokens to burn from owner.
    /// @return assets    wstETH returned to receiver.
    function redeemTranched(uint256 shares, address receiver, address owner, uint256 pToBurn, uint256 nToBurn)
        external
        returns (uint256 assets)
    {
        VaultStorage storage $ = _getVaultStorage();
        ITrancher($.trancher).merge(owner, shares, pToBurn, nToBurn);
        assets = super.redeem(shares, receiver, owner);
        $.totalDeposited = $.totalDeposited > assets ? $.totalDeposited - assets : 0;
    }

    /* //////////////////////////////////////////////////////////////
                       ASYNC BATCH EXIT — PHASE 1
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IVault
    ///
    /// @dev    Fix 1 — Allowance check:
    ///           When owner != msg.sender, _spendAllowance() is called before
    ///           _transfer(). Solady's internal _transfer bypasses ERC-20 allowances;
    ///           without this guard ANY caller could forcibly lock any user's shares.
    ///
    ///         Fix 4 — Slippage guard:
    ///           minAssetsLocked: if non-zero, reverts when the snapshotted assets
    ///           fall below the caller's minimum (prevents sandwich attacks on the
    ///           wstETH exchange rate between submission and inclusion).
    ///
    ///         CEI order:
    ///           1. Validate inputs
    ///           2. Compute assetsLocked (exchange rate snapshot)
    ///           3. Slippage check
    ///           4. Burn P+N via Trancher.merge()   [effect on trancher state]
    ///           5. Spend allowance + transfer shares [effect on share state]
    ///           6. Update batch accounting           [effect on batch state]
    ///           7. Store request                     [effect on request state]
    ///           8. Emit event
    ///
    ///         Note: totalDeposited is NOT decremented here. It is decremented in
    ///         settleBatch() when vault shares are actually burned.
    function requestRedeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 pToBurn,
        uint256 nToBurn,
        uint128 minAssetsLocked
    ) external override returns (bytes32 requestId) {
        if (shares == 0) revert Vault_ZeroAssets();

        VaultStorage storage $ = _getVaultStorage();

        // Validate: current batch must be open.
        bytes32 batchId = $.currentBatchId;
        BatchTypes.BatchInfo storage batch = $.batches[batchId];
        if (batch.isClosed) revert Vault_BatchAlreadyClosed(batchId);

        // Snapshot the exchange rate at request time (not settlement time).
        // This prevents wstETH yield accrued during the bridge delay from
        // leaking to exiting users at the expense of remaining depositors.
        uint128 assetsLocked = uint128(previewRedeem(shares));

        // Fix 4: slippage guard — reverts if the snapshotted exchange rate is
        // worse than the caller's minimum acceptable floor.
        if (minAssetsLocked > 0 && assetsLocked < minAssetsLocked) {
            revert Vault_SlippageExceeded(assetsLocked, minAssetsLocked);
        }

        // Phase 1: Burn P and N tokens immediately (tranche invariant evaluated now).
        ITrancher($.trancher).merge(owner, shares, pToBurn, nToBurn);

        // Fix 1: Allowance check for delegated requests.
        // When owner == msg.sender this is a self-initiated exit and no
        // allowance is required (same as standard ERC-4626 redeem pattern).
        // When owner != msg.sender the caller MUST have been approved to spend
        // the owner's vault shares — enforced by _spendAllowance().
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _transfer(owner, address(this), shares);

        // Update batch aggregate state.
        batch.totalSharesQueued += uint128(shares);
        batch.totalAssetsLocked += assetsLocked;

        // Update global pending tracker.
        $.totalPendingRedemption += uint128(shares);

        // Generate deterministic requestId.
        requestId = keccak256(abi.encode(address(this), owner, shares, block.timestamp, $.requestCounter++));

        // Store the request.
        $.requests[requestId] = BatchTypes.RedemptionRequest({
            user: owner,
            receiver: receiver,
            batchId: batchId,
            shares: uint128(shares),
            pBurned: uint128(pToBurn),
            nBurned: uint128(nToBurn),
            assetsLocked: assetsLocked,
            requestTimestamp: uint64(block.timestamp),
            status: BatchTypes.RequestStatus.PENDING
        });

        emit RedemptionRequested(
            requestId, batchId, owner, receiver, uint128(shares), uint128(pToBurn), uint128(nToBurn), assetsLocked
        );
    }

    /// @inheritdoc IVault
    function requestWithdraw(uint256 assets, address receiver, address owner)
        external
        override
        returns (bytes32 requestId)
    {
        if (assets == 0) revert Vault_ZeroAssets();
        VaultStorage storage $ = _getVaultStorage();
        uint256 shares = previewWithdraw(assets);
        (uint256 pToBurn, uint256 nToBurn) = ITrancher($.trancher).computeMerge(owner, shares);
        return this.requestRedeem(shares, receiver, owner, pToBurn, nToBurn, 0);
    }

    /* //////////////////////////////////////////////////////////////
                       ASYNC BATCH EXIT — CANCEL
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IVault
    ///
    /// @dev    Fix 3 — Emergency cancel (pre-close only):
    ///           Reverses Phase 1 entirely. Only valid while the batch is open.
    ///           Once the keeper calls closeBatch(), the cross-chain unwind has
    ///           started and cancellation is no longer safe.
    ///
    ///         CEI order:
    ///           1. Validate request exists and is PENDING.
    ///           2. Validate caller is request.user.
    ///           3. Validate the batch is still open (not yet closed).
    ///           4. Mark CANCELLED (prevent re-entrancy on the state machine).
    ///           5. Decrement batch + global accounting.
    ///           6. Return vault shares to user.
    ///           7. Re-mint P and N tokens to user (exact original amounts).
    ///           8. Emit event.
    function cancelRequest(bytes32 requestId) external override {
        VaultStorage storage $ = _getVaultStorage();
        BatchTypes.RedemptionRequest storage req = $.requests[requestId];

        // Guard: request must exist.
        if (req.status == BatchTypes.RequestStatus.UNDEFINED) {
            revert Vault_RequestNotFound(requestId);
        }

        // Guard: only the original requester may cancel.
        if (msg.sender != req.user) {
            revert Vault_NotRequestOwner(msg.sender, req.user);
        }

        // Guard: request must still be PENDING (not already claimed or cancelled).
        if (req.status != BatchTypes.RequestStatus.PENDING) {
            revert Vault_RequestNotCancellable(requestId);
        }

        // Guard: can only cancel while the batch is still open.
        BatchTypes.BatchInfo storage batch = $.batches[req.batchId];
        if (batch.isClosed) {
            revert Vault_CannotCancelClosedBatch(req.batchId);
        }

        uint128 shares = req.shares;
        uint128 assetsLocked = req.assetsLocked;
        uint128 pToRestore = req.pBurned;
        uint128 nToRestore = req.nBurned;
        address user = req.user;

        // CEI: mark CANCELLED before any external calls.
        req.status = BatchTypes.RequestStatus.CANCELLED;

        // Decrement batch accounting.
        batch.totalSharesQueued -= shares;
        batch.totalAssetsLocked -= assetsLocked;

        // Decrement global pending tracker.
        $.totalPendingRedemption = $.totalPendingRedemption > shares ? $.totalPendingRedemption - shares : 0;

        // Return locked vault shares from vault → user.
        _transfer(address(this), user, shares);

        // Re-mint exact P and N tokens to restore the user's original position.
        // splitExact() is restricted to vault, so this cannot be called externally.
        ITrancher($.trancher).splitExact(user, pToRestore, nToRestore);

        emit RequestCancelled(requestId, user, shares);
    }

    /* //////////////////////////////////////////////////////////////
                       ASYNC BATCH EXIT — PHASE 2
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IVault
    ///
    /// @dev    Only the settler (keeper) may close a batch.
    ///         Closing stops new requests from joining this batch, signals the
    ///         keeper to downsize the perp on Hyperliquid, and opens a new batch
    ///         so deposits and new requests continue uninterrupted.
    function closeBatch() external override returns (bytes32 closedBatchId, bytes32 newBatchId) {
        VaultStorage storage $ = _getVaultStorage();
        _checkSettler($);

        closedBatchId = $.currentBatchId;
        BatchTypes.BatchInfo storage batch = $.batches[closedBatchId];

        if (batch.isClosed) revert Vault_BatchAlreadyClosed(closedBatchId);

        batch.isClosed = true;
        emit BatchClosed(closedBatchId, batch.totalSharesQueued, batch.totalAssetsLocked);

        // Immediately open a new batch so deposits and new requests can continue.
        newBatchId = _openNewBatch($);
    }

    /// @inheritdoc IVault
    ///
    /// @dev    CEI order (critical for correctness):
    ///           1. Guards: settler check, batch closed, not already settled.
    ///           2. Pull wstETH from settler (they must have approved this contract).
    ///           3. Burn the locked vault shares.
    ///           4. Update totalDeposited (reduce by pro-rata assets estimate).
    ///           5. Update totalPendingRedemption.
    ///           6. Write settlement data to batch.
    ///           7. Emit event.
    ///
    ///         The wstETH pull (step 2) uses the standard ERC-20 transferFrom pattern.
    ///         The settler bridges from Hyperliquid → EVM, then calls settleBatch().
    function settleBatch(bytes32 batchId, uint128 assetsReturned) external override {
        if (assetsReturned == 0) revert Vault_ZeroAssetsReturned();

        VaultStorage storage $ = _getVaultStorage();
        _checkSettler($);

        BatchTypes.BatchInfo storage batch = $.batches[batchId];

        // Validate batch state.
        if (batch.openedAtBlock == 0) revert Vault_BatchNotFound(batchId);
        if (!batch.isClosed) revert Vault_BatchNotClosed(batchId);
        if (batch.isSettled) revert Vault_BatchAlreadySettled(batchId);

        // Pull bridged wstETH from settler (settler must have approved vault).
        SafeTransferLib.safeTransferFrom($.asset, msg.sender, address(this), assetsReturned);

        // Burn the vault shares locked in this batch.
        // These shares have been sitting in this contract since Phase 1.
        uint256 sharesToBurn = batch.totalSharesQueued;
        if (sharesToBurn > 0) {
            _burn(address(this), sharesToBurn);
        }

        // Decrement totalDeposited by the locked assets amount (request-time snapshot).
        // This is the same value the Trancher used for P/N coverage during the window.
        uint256 assetsLocked = batch.totalAssetsLocked;
        $.totalDeposited = $.totalDeposited > assetsLocked ? $.totalDeposited - assetsLocked : 0;

        // Decrement global pending tracker.
        $.totalPendingRedemption =
            $.totalPendingRedemption > uint128(sharesToBurn) ? $.totalPendingRedemption - uint128(sharesToBurn) : 0;

        // Mark batch settled and record the actual bridged amount.
        batch.isSettled = true;
        batch.assetsReturned = assetsReturned;

        emit BatchSettled(batchId, assetsReturned);
    }

    /* //////////////////////////////////////////////////////////////
                       ASYNC BATCH EXIT — PHASE 3
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IVault
    ///
    /// @dev    Pro-rata formula:
    ///           userClaim = assetsReturned * request.assetsLocked / batch.totalAssetsLocked
    ///
    ///         If assetsReturned < totalAssetsLocked (bridge slippage / fees), each user
    ///         receives a proportionally reduced amount. No user receives more than their
    ///         assetsLocked, and no user is left with zero unless the batch returned nothing.
    ///
    ///         CEI: mark CLAIMED before transferring (prevents re-entrancy even if wstETH
    ///         had a receive-hook, which it does not — wstETH is standard ERC-20).
    function claimRedeemedAssets(bytes32 requestId) external override returns (uint256 assets) {
        VaultStorage storage $ = _getVaultStorage();
        BatchTypes.RedemptionRequest storage req = $.requests[requestId];

        // Validate request exists.
        if (req.status == BatchTypes.RequestStatus.UNDEFINED) {
            revert Vault_RequestNotFound(requestId);
        }

        // Validate caller is the original requestor.
        if (msg.sender != req.user) {
            revert Vault_NotRequestOwner(msg.sender, req.user);
        }

        // Validate request is still claimable (PENDING — not already CLAIMED or CANCELLED).
        if (req.status != BatchTypes.RequestStatus.PENDING) {
            revert Vault_RequestNotPending(requestId);
        }

        // Validate batch has been settled.
        BatchTypes.BatchInfo storage batch = $.batches[req.batchId];
        if (!batch.isSettled) {
            revert Vault_BatchNotSettled(req.batchId);
        }

        // Compute pro-rata claim.
        // assetsReturned * assetsLocked / totalAssetsLocked.
        // Safe: assetsReturned and assetsLocked are both uint128; product fits in uint256.
        assets = (uint256(batch.assetsReturned) * uint256(req.assetsLocked)) / uint256(batch.totalAssetsLocked);

        // CEI: mark CLAIMED before transfer.
        req.status = BatchTypes.RequestStatus.CLAIMED;
        batch.claimedAssets += uint128(assets);

        address receiver = req.receiver;

        // Transfer wstETH to the receiver.
        SafeTransferLib.safeTransfer($.asset, receiver, assets);

        emit AssetsClaimed(requestId, req.user, receiver, uint128(assets));
    }

    /* //////////////////////////////////////////////////////////////
                          IVault VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IVault
    function currentBatchId() external view override returns (bytes32) {
        return _getVaultStorage().currentBatchId;
    }

    /// @inheritdoc IVault
    function totalPendingRedemption() external view override returns (uint128) {
        return _getVaultStorage().totalPendingRedemption;
    }

    /// @inheritdoc IVault
    function getBatch(bytes32 batchId) external view override returns (BatchTypes.BatchInfo memory) {
        return _getVaultStorage().batches[batchId];
    }

    /// @inheritdoc IVault
    function getRequest(bytes32 requestId) external view override returns (BatchTypes.RedemptionRequest memory) {
        return _getVaultStorage().requests[requestId];
    }

    /* //////////////////////////////////////////////////////////////
                          IVault FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IVault
    /// @dev Returns hedgeCoverage as perpNotional / totalDepositedAssets
    ///      (flash-loan-resistant denominator, consistent with Trancher).
    function hedgeCoverage() external view override returns (uint256) {
        VaultStorage storage $ = _getVaultStorage();
        uint256 deposited = $.totalDeposited;
        if (deposited == 0) return SCALE;
        if ($.optionAdapter == address(0)) return 0;
        uint256 notional = IPerpAdapter($.optionAdapter).totalHedgedNotional();
        if (notional >= deposited) return SCALE;
        return (notional * SCALE) / deposited;
    }

    /// @inheritdoc IVault
    /// @dev PERP SIZE IMBALANCE ACCOUNTING:
    ///      A 1x short perp has a constant delta of -1.0 per wstETH of notional.
    ///      The vault holds totalDepositedAssets() wstETH at spot delta +1.0 each.
    ///      For full neutrality the perp notional must equal totalDepositedAssets().
    ///
    ///      Trigger condition:
    ///        imbalance = |totalDepositedAssets() - perpNotional|
    ///        threshold = totalDepositedAssets() x IMBALANCE_THRESHOLD_BPS / BASIS_POINTS_DENOMINATOR
    ///        if imbalance > threshold => emit IntentRequested(sizeDelta, timestamp)
    ///
    ///      sizeDelta sign convention:
    ///        + (positive): vault has MORE collateral than perp notional => increase short.
    ///        - (negative): perp notional exceeds vault collateral => reduce short.
    function checkAndEmitIntent() external override {
        VaultStorage storage $ = _getVaultStorage();
        if ($.optionAdapter == address(0)) revert Vault_AdapterNotSet();

        uint256 deposited = $.totalDeposited;
        uint256 notional = IPerpAdapter($.optionAdapter).totalHedgedNotional();

        uint256 imbalance = deposited > notional ? deposited - notional : notional - deposited;

        // Fix 6: replaced magic 10_000 with named constant.
        uint256 threshold = (deposited * IMBALANCE_THRESHOLD_BPS) / Constants.BASIS_POINTS_DENOMINATOR;

        if (imbalance > threshold) {
            int256 sizeDelta = int256(deposited) - int256(notional);
            emit IntentRequested(sizeDelta, block.timestamp);
        }
    }

    /* //////////////////////////////////////////////////////////////
                         OWNERSHIP & ACCESS CONTROL
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IVault
    /// @dev Fix 2: setSettler is now owner-only.
    ///      WARNING: In production, the owner should be a multisig or timelock.
    function setSettler(address settler_) external override {
        _checkOwner();
        if (settler_ == address(0)) revert Vault_ZeroAddress();
        VaultStorage storage $ = _getVaultStorage();
        $.settler = settler_;
        emit SettlerSet(settler_);
    }

    /// @inheritdoc IVault
    /// @dev Fix 2: transfer ownership to a multisig after initial deployment.
    function transferOwnership(address newOwner) external override {
        _checkOwner();
        if (newOwner == address(0)) revert Vault_ZeroAddress();
        VaultStorage storage $ = _getVaultStorage();
        address prev = $.owner;
        $.owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    /* //////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    ////////////////////////////////////////////////////////////// */

    /// @dev Revert if msg.sender is not the contract owner (Fix 2).
    function _checkOwner() internal view {
        VaultStorage storage $ = _getVaultStorage();
        if (msg.sender != $.owner) revert Vault_OnlyOwner(msg.sender);
    }

    /// @dev Revert if msg.sender is not the configured settler.
    function _checkSettler(VaultStorage storage $) internal view {
        if ($.settler == address(0)) revert Vault_SettlerNotSet();
        if (msg.sender != $.settler) revert Vault_OnlySettler(msg.sender);
    }

    /// @dev Opens a new batch, writes its initial state, and updates currentBatchId.
    ///      Returns the new batchId.
    function _openNewBatch(VaultStorage storage $) internal returns (bytes32 newBatchId) {
        newBatchId = keccak256(abi.encode(address(this), $.batchCounter++, block.chainid, block.timestamp));

        $.batches[newBatchId] = BatchTypes.BatchInfo({
            isClosed: false,
            isSettled: false,
            openedAtBlock: uint64(block.number),
            totalSharesQueued: 0,
            totalAssetsLocked: 0,
            assetsReturned: 0,
            claimedAssets: 0
        });

        $.currentBatchId = newBatchId;
        emit BatchOpened(newBatchId, uint64(block.number));
    }
}
