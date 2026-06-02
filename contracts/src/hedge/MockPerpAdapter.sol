// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPerpAdapter} from "./IPerpAdapter.sol";

/// @title  MockPerpAdapter
/// @author OptionZero
/// @notice Deterministic mock implementation of IPerpAdapter for POC testing.
///         Simulates a 1x short ETH perpetual futures position without any
///         external protocol dependency.
///
/// @dev    Simulation model:
///
///           DELTA:   Always exactly -1.0e18. A 1x short perp carries a
///                    constant portfolio delta of -1. No gamma, no re-hedging
///                    required due to price moves. This is the fundamental
///                    advantage of perps over options.
///
///           FUNDING: Accrues per-block as:
///                      accruedFunding = fundingRatePerBlock
///                                     × (block.number - _lastSettlementBlock)
///                                     × _totalHedgedNotional / 1e18
///                    Signed: positive = vault earns (longs pay shorts).
///                            negative = vault pays (shorts pay longs).
///
///           POSITIONS: Stored deterministically by positionId. openPosition()
///                    hashes caller + notional + block to produce a predictable
///                    positionId for test assertions.
///
/// @custom:security-contact security@optionszero.xyz
/// @custom:storage-location erc7201:optionszero.storage.mockperpadapter
contract MockPerpAdapter is IPerpAdapter {
    /* //////////////////////////////////////////////////////////////
                               CONSTANTS
    ////////////////////////////////////////////////////////////// */

    /// @notice Delta of a 1x short perp: always exactly -1.0 (18 decimals).
    /// @dev    This is a mathematical invariant — not configurable. A 1x short
    ///         perp hedges exactly one unit of spot exposure, period.
    int256 public constant PERP_DELTA = -1e18;

    /// @notice Default funding rate per block (positive = vault earns).
    /// @dev    1e9 per block ≈ tiny positive rate. Tests override via setMockFundingRate().
    int256 public constant DEFAULT_FUNDING_RATE = 1e9;

    /* //////////////////////////////////////////////////////////////
                            ERC-7201 STORAGE
    ////////////////////////////////////////////////////////////// */

    /// @custom:storage-location erc7201:optionszero.storage.mockperpadapter
    struct PerpAdapterStorage {
        /// @dev Signed funding rate per block. Positive = vault earns.
        int256 fundingRate;
        /// @dev Block number when funding was last settled.
        uint256 lastSettlementBlock;
        /// @dev Total wstETH notional across all open positions (1e18 = 1 wstETH).
        uint256 totalHedgedNotional;
        /// @dev Monotonically increasing counter for deterministic positionId generation.
        uint256 positionCount;
        /// @dev Owner address (set in constructor; controls setFundingRate()).
        address owner;
        /// @dev Per-position notional mapping.
        mapping(bytes32 => uint256) positionNotional;
    }

    /// @dev Slot: keccak256(abi.encode(uint256(keccak256("optionszero.storage.mockperpadapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION = 0x9c241f92b8f7a428c28c49cd0ac62765b8e1e9b1d29c52a91d30f02c4b3e2100;

    function _getStorage() private pure returns (PerpAdapterStorage storage $) {
        assembly {
            $.slot := _STORAGE_LOCATION
        }
    }

    /* //////////////////////////////////////////////////////////////
                                ERRORS
    ////////////////////////////////////////////////////////////// */

    /// @dev Reverts when a position ID does not exist.
    error MockPerpAdapter_PositionNotFound(bytes32 positionId);

    /// @dev Reverts when the caller is not the owner.
    error MockPerpAdapter_OnlyOwner(address caller);

    /* //////////////////////////////////////////////////////////////
                                EVENTS
    ////////////////////////////////////////////////////////////// */

    /// @notice Emitted when accrued funding is settled and the counter resets.
    /// @param  amount Signed funding settled (positive = vault received).
    event FundingSettled(int256 amount);

    /// @notice Emitted when a new short perp position is opened.
    /// @param  posId    Unique position identifier.
    /// @param  notional wstETH notional of the new position (1e18).
    event PositionOpened(bytes32 indexed posId, uint256 notional);

    /// @notice Emitted when an existing position is resized.
    /// @param  posId        Unique position identifier.
    /// @param  oldNotional  Previous wstETH notional.
    /// @param  newNotional  Updated wstETH notional.
    event PositionResized(bytes32 indexed posId, uint256 oldNotional, uint256 newNotional);

    /// @notice Emitted when a position is fully closed.
    /// @param  posId    Unique position identifier.
    /// @param  notional wstETH notional of the closed position.
    event PositionClosed(bytes32 indexed posId, uint256 notional);

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    /// @notice Deploys the mock with default positive funding rate.
    /// @dev    Sets `owner` to `msg.sender` for the privileged `setFundingRate` setter.
    constructor() {
        PerpAdapterStorage storage $ = _getStorage();
        $.fundingRate = DEFAULT_FUNDING_RATE;
        $.lastSettlementBlock = block.number;
        $.owner = msg.sender;
    }

    /* //////////////////////////////////////////////////////////////
                          TEST HARNESS SETTERS
    ////////////////////////////////////////////////////////////// */

    /// @notice Update the funding rate per block. Owner-only.
    /// @dev    In production, the real IPerpAdapter does NOT expose this.
    ///         This setter exists exclusively on the mock for test control.
    /// @param  rate New signed funding rate per block (positive = vault earns).
    function setFundingRate(int256 rate) external {
        PerpAdapterStorage storage $ = _getStorage();
        if (msg.sender != $.owner) revert MockPerpAdapter_OnlyOwner(msg.sender);
        $.fundingRate = rate;
    }

    /// @notice Alias for setFundingRate with no access control.
    /// @dev    Convenience for test harnesses that do not track ownership.
    ///         WARNING: never replicate this pattern in production adapters.
    /// @param  rate New signed funding rate per block.
    function setMockFundingRate(int256 rate) external {
        _getStorage().fundingRate = rate;
    }

    /* //////////////////////////////////////////////////////////////
                    IPerpAdapter — VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IPerpAdapter
    /// @dev    Immutable mathematical property of a 1x short perp.
    ///         No gamma — delta never drifts with price.
    function currentDelta() external pure override returns (int256) {
        return PERP_DELTA;
    }

    /// @inheritdoc IPerpAdapter
    function totalHedgedNotional() external view override returns (uint256) {
        return _getStorage().totalHedgedNotional;
    }

    /// @inheritdoc IPerpAdapter
    /// @dev    Funding = fundingRate × blocks_elapsed × totalHedgedNotional / 1e18.
    ///         Returns 0 if no positions are open (notional == 0).
    ///         Signed: positive = vault earns, negative = vault pays.
    function accruedFunding() external view override returns (int256) {
        PerpAdapterStorage storage $ = _getStorage();
        if ($.totalHedgedNotional == 0) return 0;
        int256 blocksDelta = int256(block.number - $.lastSettlementBlock);
        return $.fundingRate * blocksDelta * int256($.totalHedgedNotional) / 1e18;
    }

    /// @inheritdoc IPerpAdapter
    function fundingRatePerBlock() external view override returns (int256) {
        return _getStorage().fundingRate;
    }

    /* //////////////////////////////////////////////////////////////
                   IPerpAdapter — MUTATORS
    ////////////////////////////////////////////////////////////// */

    /// @inheritdoc IPerpAdapter
    /// @dev    positionId = keccak256(msg.sender ‖ notionalWstETH ‖ block.number ‖ positionCount++).
    ///         Deterministic and unique per caller per block.
    function openPosition(uint256 notionalWstETH) external override returns (bytes32 positionId) {
        PerpAdapterStorage storage $ = _getStorage();

        positionId = keccak256(abi.encodePacked(msg.sender, notionalWstETH, block.number, $.positionCount++));

        $.positionNotional[positionId] = notionalWstETH;
        $.totalHedgedNotional += notionalWstETH;

        emit PositionOpened(positionId, notionalWstETH);
    }

    /// @inheritdoc IPerpAdapter
    /// @dev    Updates _totalHedgedNotional by the signed delta between old and new notional.
    ///         Reverts if the positionId is unknown.
    function resizePosition(bytes32 positionId, uint256 newNotionalWstETH) external override {
        PerpAdapterStorage storage $ = _getStorage();
        uint256 old = $.positionNotional[positionId];
        if (old == 0 && newNotionalWstETH == 0) revert MockPerpAdapter_PositionNotFound(positionId);

        emit PositionResized(positionId, old, newNotionalWstETH);

        // Adjust total notional by the signed delta.
        if (newNotionalWstETH >= old) {
            $.totalHedgedNotional += (newNotionalWstETH - old);
        } else {
            $.totalHedgedNotional -= (old - newNotionalWstETH);
        }

        $.positionNotional[positionId] = newNotionalWstETH;
    }

    /// @inheritdoc IPerpAdapter
    function closePosition(bytes32 positionId) external override {
        PerpAdapterStorage storage $ = _getStorage();
        uint256 notional = $.positionNotional[positionId];
        if (notional == 0) revert MockPerpAdapter_PositionNotFound(positionId);

        $.totalHedgedNotional -= notional;
        $.positionNotional[positionId] = 0;

        emit PositionClosed(positionId, notional);
    }

    /// @inheritdoc IPerpAdapter
    /// @dev    Snapshots the accrued funding BEFORE resetting the block counter
    ///         so the emitted amount is correct.
    function settleFunding() external override returns (int256 settled) {
        PerpAdapterStorage storage $ = _getStorage();

        // Snapshot first — resetting the clock zeroes out accruedFunding().
        if ($.totalHedgedNotional > 0) {
            int256 blocksDelta = int256(block.number - $.lastSettlementBlock);
            settled = $.fundingRate * blocksDelta * int256($.totalHedgedNotional) / 1e18;
        }

        $.lastSettlementBlock = block.number; // reset second
        emit FundingSettled(settled);
    }
}
