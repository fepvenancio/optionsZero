// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title  Constants
/// @notice Shared numeric constants for the OptionZero protocol.
///         Centralising these eliminates the risk of silent divergence when
///         the same literal is redefined independently across multiple contracts.
library Constants {
    /* //////////////////////////////////////////////////////////////
                           FIXED-POINT SCALING
    ////////////////////////////////////////////////////////////// */

    /// @notice WAD: 18-decimal fixed-point unit used throughout the protocol.
    ///         1e18 == 1 wstETH == 1 vault share == 1 P/N token (at par).
    uint256 internal constant SCALE = 1e18;

    /* //////////////////////////////////////////////////////////////
                           BASIS POINTS
    ////////////////////////////////////////////////////////////// */

    /// @notice Denominator for basis-point fractions (1 bps = 0.01%).
    ///         Use as: `value * bps / BASIS_POINTS_DENOMINATOR`.
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10_000;
}
