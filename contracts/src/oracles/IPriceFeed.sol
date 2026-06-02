// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IPriceFeed
/// @notice Minimal price oracle interface consumed by Vault and Trancher.
///         Returns ETH/USD price and the wstETH/stETH exchange rate, both
///         sourced from Chainlink-compatible aggregators in the POC.
/// @dev    All prices use the Chainlink 8-decimal convention (1e8 = $1.00).
///         The wstETH rate uses 18-decimal convention (1e18 = 1 stETH).
interface IPriceFeed {
    /* ///////////////////////////////////////////////////////////////
                                 ERRORS
    /////////////////////////////////////////////////////////////// */

    /// @dev Reverts when a price feed returns a stale answer.
    error IPriceFeed_StalePrice(uint256 updatedAt, uint256 maxAge);

    /// @dev Reverts when a price feed returns a non-positive answer.
    error IPriceFeed_InvalidPrice(int256 answer);

    /* ///////////////////////////////////////////////////////////////
                                FUNCTIONS
    /////////////////////////////////////////////////////////////// */

    /// @notice Returns the current ETH/USD price.
    /// @return price ETH/USD price, 8 decimals (e.g. 3_000_00000000 = $3,000).
    function getEthUsdPrice() external view returns (uint256 price);

    /// @notice Returns the current wstETH/stETH exchange rate.
    /// @dev    Equivalent to calling `wstETH.stEthPerToken()`.
    /// @return rate wstETH-to-stETH rate, 18 decimals (1e18 = 1 stETH per wstETH).
    function getWstETHRate() external view returns (uint256 rate);

    /// @notice Converts a wstETH amount to its USD value.
    /// @param  wstETHAmount Amount of wstETH, 18 decimals.
    /// @return usdValue     USD value, 18 decimals.
    function wstETHToUSD(uint256 wstETHAmount) external view returns (uint256 usdValue);
}
