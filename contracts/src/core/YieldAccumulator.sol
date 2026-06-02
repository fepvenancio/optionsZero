// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPerpAdapter} from "../hedge/IPerpAdapter.sol";
import {IPriceFeed} from "../oracles/IPriceFeed.sol";

/// @title  YieldAccumulator
/// @author OptionZero
/// @notice Tracks the liquid staking yield accrued by the wstETH collateral
///         held in Vault and uses that yield as a budget to absorb perp funding
///         costs. This is the economic engine that makes the P tranche peg
///         self-sustaining:
///
///           yield_budget  = Δ(wstETH_rate) × totalCollateral_wstETH
///           funding_owed  = IPerpAdapter.accruedFunding()   (signed)
///           surplus       = yield_budget + funding_owed     (flows to N holders)
///
///         When funding is positive (longs pay shorts) the vault earns; the budget
///         check always passes because `funding_owed > 0` means the vault is
///         receiving rather than paying. When funding is negative the vault pays,
///         and the yield budget must be sufficient to cover the shortfall.
///
/// @dev    Snapshots the wstETH/stETH exchange rate on each call to `snapshot()`.
///         Called by Vault or the keeper bot at regular intervals (e.g. daily).
///
///         All amounts are in wstETH (18 decimals) unless stated otherwise.
///
/// @custom:storage-location erc7201:optionszero.storage.kyieldaccumulator
contract YieldAccumulator {
    /* //////////////////////////////////////////////////////////////
                               CONSTANTS
    ////////////////////////////////////////////////////////////// */

    /// @notice ERC-7201 storage slot.
    /// @dev    keccak256(abi.encode(uint256(keccak256("optionszero.storage.kyieldaccumulator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _YIELD_STORAGE_LOCATION =
        0x6e8a35de8d3be2e3b0b5e6e6ab6e4b1b0c1a4e7e2b5d6e5f3a2b1c0d9e8f7a00;

    /* //////////////////////////////////////////////////////////////
                          NAMESPACED STORAGE
    ////////////////////////////////////////////////////////////// */

    /// @custom:storage-location erc7201:optionszero.storage.kyieldaccumulator
    struct YieldStorage {
        /// @dev wstETH/stETH exchange rate at last snapshot (1e18).
        uint256 lastWstETHRate;
        /// @dev Total wstETH yield accumulated since genesis.
        uint256 totalYieldAccumulated;
        /// @dev Total perp funding cost consumed from the yield budget (unsigned).
        ///      Only negative-funding episodes reduce this; positive funding is
        ///      additive to the budget.
        uint256 totalFundingConsumed;
        /// @dev Timestamp of last snapshot.
        uint256 lastSnapshotTime;
        /// @dev Reference to the wstETH-like rate provider.
        address pricer;
        /// @dev Reference to the perp adapter for funding reads.
        address perpAdapter;
        /// @dev Reference to the Vault for totalAssets reads.
        address vault;
    }

    function _getYieldStorage() internal pure returns (YieldStorage storage $) {
        assembly {
            $.slot := _YIELD_STORAGE_LOCATION
        }
    }

    /* //////////////////////////////////////////////////////////////
                               ERRORS
    ////////////////////////////////////////////////////////////// */

    /// @dev Reverts if the Vault caller check fails (reserved for future access control).
    error YieldAccumulator_OnlyVault(address caller);

    /// @dev Reverts if snapshot() is called before initialisation.
    error YieldAccumulator_NotInitialized();

    /// @dev Reverts when the accumulated yield budget is insufficient to cover
    ///      the perp funding cost. Triggers a circuit breaker; N holders absorb loss.
    /// @param  required  Funding cost to be settled (wstETH, 1e18).
    /// @param  available Current yield budget (wstETH, 1e18).
    error YieldAccumulator_InsufficientBudget(uint256 required, uint256 available);

    /* //////////////////////////////////////////////////////////////
                               EVENTS
    ////////////////////////////////////////////////////////////// */

    /// @notice Emitted after each yield snapshot.
    /// @param yieldDelta  New yield accrued since last snapshot (wstETH, 1e18).
    /// @param newRate     Updated wstETH/stETH rate (1e18).
    event YieldSnapshotted(uint256 yieldDelta, uint256 newRate);

    /// @notice Emitted when perp funding cost is consumed from the yield budget.
    /// @param  amount  Funding cost consumed (wstETH, 1e18). Always a positive magnitude.
    /// @param  surplus Remaining yield budget after consumption (wstETH, 1e18).
    event FundingConsumed(uint256 amount, uint256 surplus);

    /* //////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    /// @param vault_       Address of Vault.
    /// @param pricer_      Address of IPriceFeed.
    /// @param perpAdapter_ Address of IPerpAdapter.
    constructor(address vault_, address pricer_, address perpAdapter_) {
        YieldStorage storage $ = _getYieldStorage();
        $.vault = vault_;
        $.pricer = pricer_;
        $.perpAdapter = perpAdapter_;
        $.lastSnapshotTime = block.timestamp;
        // Record initial rate; first snapshot will compute delta from here.
        $.lastWstETHRate = IPriceFeed(pricer_).getWstETHRate();
    }

    /* //////////////////////////////////////////////////////////////
                        STATE-CHANGING FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @notice Record a yield snapshot and settle pending perp funding.
    /// @dev    Can be called by anyone (keeper-bot or Vault hooks).
    ///         Emits YieldSnapshotted and optionally FundingConsumed.
    ///
    ///         Funding sign handling:
    ///           funding > 0  → longs pay shorts → vault EARNS → budget always passes.
    ///           funding < 0  → shorts pay longs → vault PAYS  → budget check required.
    ///           funding == 0 → no settlement needed.
    function snapshot() external {
        YieldStorage storage $ = _getYieldStorage();

        uint256 currentRate = IPriceFeed($.pricer).getWstETHRate();
        uint256 lastRate = $.lastWstETHRate;

        // Compute yield delta: rate growth × total collateral.
        // totalAssets() returns wstETH units; yield accrues as rate grows.
        uint256 totalCollateral = _vaultTotalAssets();
        uint256 yieldDelta = 0;

        if (currentRate > lastRate && totalCollateral > 0) {
            // yieldDelta (in wstETH) = totalCollateral × (currentRate - lastRate) / lastRate
            yieldDelta = (totalCollateral * (currentRate - lastRate)) / lastRate;
        }

        $.lastWstETHRate = currentRate;
        $.totalYieldAccumulated += yieldDelta;
        $.lastSnapshotTime = block.timestamp;

        emit YieldSnapshotted(yieldDelta, currentRate);

        // Settle accrued funding if any.
        int256 funding = IPerpAdapter($.perpAdapter).accruedFunding();

        if (funding > 0) {
            // Vault earns — credit the budget, no check needed.
            $.totalYieldAccumulated += uint256(funding);
            IPerpAdapter($.perpAdapter).settleFunding();
            emit FundingConsumed(0, availableBudget());
        } else if (funding < 0) {
            // Vault pays — must have budget to cover.
            uint256 fundingCost = uint256(-funding);
            _settleFunding($, fundingCost);
        }
    }

    /* //////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @notice Current yield budget available to pay perp funding costs.
    /// @return budget wstETH available (1e18).
    function availableBudget() public view returns (uint256 budget) {
        YieldStorage storage $ = _getYieldStorage();
        uint256 consumed = $.totalFundingConsumed;
        uint256 accrued = $.totalYieldAccumulated;
        budget = accrued > consumed ? accrued - consumed : 0;
    }

    /// @notice Total yield ever accumulated since genesis (wstETH, 1e18).
    function totalYieldAccumulated() external view returns (uint256) {
        return _getYieldStorage().totalYieldAccumulated;
    }

    /// @notice Total perp funding cost ever consumed from the yield budget (wstETH, 1e18).
    function totalFundingConsumed() external view returns (uint256) {
        return _getYieldStorage().totalFundingConsumed;
    }

    /* //////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    ////////////////////////////////////////////////////////////// */

    /// @dev Settles a negative funding episode: deducts from yield budget.
    ///      Reverts with YieldAccumulator_InsufficientBudget if budget is too low.
    function _settleFunding(YieldStorage storage $, uint256 fundingCost) internal {
        uint256 budget =
            $.totalYieldAccumulated > $.totalFundingConsumed ? $.totalYieldAccumulated - $.totalFundingConsumed : 0;

        if (fundingCost > budget) revert YieldAccumulator_InsufficientBudget(fundingCost, budget);

        $.totalFundingConsumed += fundingCost;
        IPerpAdapter($.perpAdapter).settleFunding();

        emit FundingConsumed(fundingCost, budget - fundingCost);
    }

    /// @dev Reads totalAssets from Vault without a hard import to avoid circular deps.
    function _vaultTotalAssets() internal view returns (uint256) {
        // Low-level staticcall to `totalAssets()` selector.
        (bool ok, bytes memory data) = _getYieldStorage().vault.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
