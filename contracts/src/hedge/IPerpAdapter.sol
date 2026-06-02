// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IPerpAdapter
/// @notice Abstraction over a perpetual futures venue (e.g. Hyperliquid).
///         The vault holds wstETH and opens a 1x short ETH perp to eliminate
///         spot price delta. Delta is structurally -1.0e18 — constant, no gamma.
///
/// @dev    Notional amounts are expressed in wstETH units (same denomination
///         as vault.totalAssets()) to allow direct comparison without an
///         on-chain oracle in the POC. A production adapter converts to USD.
interface IPerpAdapter {
    /* ------------------------------------------------------------------ */
    /*  Views                                                              */
    /* ------------------------------------------------------------------ */

    /// @notice Portfolio delta of the short perp position.
    /// @dev    Always returns -1.0e18. A 1x short perp has constant delta
    ///         of exactly -1. No gamma drift — no re-hedging needed on price moves.
    function currentDelta() external view returns (int256);

    /// @notice Total wstETH notional of the active short perp position.
    /// @dev    Expressed in wstETH units (1e18 = 1 wstETH).
    ///         Used by Trancher to compute P/N coverage and by Vault to
    ///         detect collateral imbalances requiring a perp resize.
    function totalHedgedNotional() external view returns (uint256);

    /// @notice Funding accrued since last settlement.
    /// @dev    Positive  = longs pay shorts  = vault earns  (common case).
    ///         Negative  = shorts pay longs  = vault pays  (absorbed by N tranche).
    ///         Scaled as WAD per wstETH of notional × blocks elapsed.
    function accruedFunding() external view returns (int256);

    /// @notice Current funding rate per block.
    /// @dev    Positive = longs pay shorts. Negative = shorts pay longs.
    function fundingRatePerBlock() external view returns (int256);

    /* ------------------------------------------------------------------ */
    /*  Mutators — position lifecycle                                      */
    /* ------------------------------------------------------------------ */

    /// @notice Open a new short perp position.
    /// @param  notionalWstETH  Position size in wstETH units.
    /// @return positionId      Unique identifier for the position.
    function openPosition(uint256 notionalWstETH) external returns (bytes32 positionId);

    /// @notice Resize an existing position to a new notional.
    /// @dev    Increases or decreases the position. Excess is closed, deficit opened.
    /// @param  positionId      ID returned by openPosition.
    /// @param  newNotionalWstETH  New target notional in wstETH units.
    function resizePosition(bytes32 positionId, uint256 newNotionalWstETH) external;

    /// @notice Fully close a position and return any margin.
    /// @param  positionId  ID returned by openPosition.
    function closePosition(bytes32 positionId) external;

    /// @notice Settle accrued funding and reset the internal counter.
    /// @return settled  Net funding settled (positive = vault received, negative = vault paid).
    function settleFunding() external returns (int256 settled);
}
