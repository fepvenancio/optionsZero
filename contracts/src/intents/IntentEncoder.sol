// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title  IntentEncoder
/// @author OptionZero
/// @notice Encodes and hashes rebalance intent payloads that the off-chain
///         Rust daemon will sign and submit to the NEAR Intents solver bus.
///
/// @dev    The outer envelope follows the ERC-7683 CrossChainOrder struct so
///         that the intent is immediately compatible with ERC-7683-aware fillers.
///         The protocol-specific data is packed into the `orderData` field as
///         an ABI-encoded RebalanceIntentData struct.
///
///         Flow:
///           1. On-chain: daemon reads emitted IntentRequested event.
///           2. Off-chain: daemon calls encodeIntent() (or replicates it in Rust)
///              to produce the bytes payload.
///           3. Off-chain: daemon hashes with hashIntent() and signs via NEAR
///              Chain Signatures MPC (v1.signer / v1.signer-prod.testnet).
///           4. Off-chain: daemon posts the assembled intent to the NEAR
///              Intents solver bus; solver fulfils cross-chain.
///
///         All intents are stateless and idempotent — replay is prevented by
///         the `nonce` and `fillDeadline` fields in the ERC-7683 envelope.
contract IntentEncoder {
    /* ///////////////////////////////////////////////////////////////
                                 STRUCTS
    /////////////////////////////////////////////////////////////// */

    /// @notice ERC-7683 CrossChainOrder envelope.
    /// @dev    Matches the canonical ERC-7683 struct exactly for solver compatibility.
    struct CrossChainOrder {
        /// @dev Protocol settler contract (Vault address on origin chain).
        address originSettler;
        /// @dev Address that authorised this order (daemon's signing address).
        address user;
        /// @dev Monotonic nonce scoped to `user`. Prevents replay.
        uint256 nonce;
        /// @dev Chain ID of the origin chain (e.g. 1 for Ethereum mainnet).
        uint256 originChainId;
        /// @dev Timestamp by which the order must be opened by a filler.
        uint32 openDeadline;
        /// @dev Timestamp by which the order must be filled by a filler.
        uint32 fillDeadline;
        /// @dev Keccak256 type hash of RebalanceIntentData for ABI disambiguation.
        bytes32 orderDataType;
        /// @dev ABI-encoded RebalanceIntentData.
        bytes orderData;
    }

    /// @notice Protocol-specific data packed into CrossChainOrder.orderData.
    struct RebalanceIntentData {
        /// @dev Vault address on the origin chain.
        address vault;
        /// @dev Delta observed at the time of intent creation (1e18).
        int256 currentDelta;
        /// @dev Target delta after rebalance (0 = fully neutral).
        int256 targetDelta;
        /// @dev Maximum acceptable slippage in basis points (e.g. 50 = 0.5%).
        uint256 maxSlippageBps;
        /// @dev ABI-encoded hedge parameters: (notionalUSD, strikePrice, expiry, isCall).
        bytes hedgeParams;
    }

    /* ///////////////////////////////////////////////////////////////
                                CONSTANTS
    /////////////////////////////////////////////////////////////// */

    /// @notice EIP-712 type hash for RebalanceIntentData.
    /// @dev    Computed off-chain and hardcoded for gas efficiency.
    bytes32 public constant REBALANCE_INTENT_TYPE_HASH = keccak256(
        "RebalanceIntentData(address vault,int256 currentDelta,int256 targetDelta,uint256 maxSlippageBps,bytes hedgeParams)"
    );

    /* ///////////////////////////////////////////////////////////////
                                FUNCTIONS
    /////////////////////////////////////////////////////////////// */

    /// @notice ABI-encode a CrossChainOrder intent for NEAR submission.
    /// @param  order The fully populated CrossChainOrder.
    /// @return encoded ABI-encoded bytes ready to be signed by the daemon.
    function encodeIntent(CrossChainOrder calldata order) external pure returns (bytes memory encoded) {
        encoded = abi.encode(order);
    }

    /// @notice Keccak256 hash of a CrossChainOrder — the payload the daemon signs.
    /// @param  order The intent to hash.
    /// @return intentHash The 32-byte hash.
    function hashIntent(CrossChainOrder calldata order) external pure returns (bytes32 intentHash) {
        intentHash = keccak256(abi.encode(order));
    }

    /// @notice Encode and hash the RebalanceIntentData inner struct.
    /// @param  data The protocol-specific rebalance parameters.
    /// @return dataHash 32-byte hash of the inner data.
    function hashRebalanceData(RebalanceIntentData calldata data) external pure returns (bytes32 dataHash) {
        dataHash = keccak256(
            abi.encode(
                REBALANCE_INTENT_TYPE_HASH,
                data.vault,
                data.currentDelta,
                data.targetDelta,
                data.maxSlippageBps,
                keccak256(data.hedgeParams)
            )
        );
    }

    /// @notice Build the orderData bytes from a RebalanceIntentData struct.
    ///         Convenience for tests; daemon replicates this logic in Rust.
    function encodeOrderData(RebalanceIntentData calldata data) external pure returns (bytes memory) {
        return abi.encode(data);
    }

    /// @notice Decode orderData bytes back into a RebalanceIntentData struct.
    function decodeOrderData(bytes calldata orderData) external pure returns (RebalanceIntentData memory) {
        return abi.decode(orderData, (RebalanceIntentData));
    }
}
