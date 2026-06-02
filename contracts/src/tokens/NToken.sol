// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title  NToken — OptionZero Net-Delta / Risky Tranche Token
/// @author OptionZero
/// @notice ERC-20 token representing the subordinated, ETH-delta-exposed
///         tranche of an OptionZero vault deposit. NToken holders absorb the
///         first dollar of loss if the hedge under-covers (tail risk), and in
///         return capture the residual stETH liquid staking yield left over
///         after subsidising the rolling options premium cost.
///
/// @dev    In the vault's loss-waterfall model:
///           1. ETH price drops → wstETH collateral value falls in USD.
///           2. The hedge (short DITM calls) offset this loss up to the
///              hedged notional.
///           3. Any residual unhedged loss is absorbed by the N tranche,
///              reducing NToken redemption value.
///           4. PToken redemption value is shielded until NToken value hits 0.
///
///         Mint and burn restricted to Trancher. 18 decimals. Not rebasing.
contract NToken is ERC20 {
    /* ///////////////////////////////////////////////////////////////
                                 STORAGE
    /////////////////////////////////////////////////////////////// */

    /// @notice Address of the Trancher contract authorised to mint/burn.
    address public immutable trancher;

    /* ///////////////////////////////////////////////////////////////
                                  ERRORS
    /////////////////////////////////////////////////////////////// */

    /// @dev Reverts when caller is not the authorised Trancher.
    error NToken_OnlyTrancher(address caller);

    /* ///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    /////////////////////////////////////////////////////////////// */

    /// @param trancher_ Address of the Trancher contract.
    constructor(address trancher_) {
        trancher = trancher_;
    }

    /* ///////////////////////////////////////////////////////////////
                               ERC-20 METADATA
    /////////////////////////////////////////////////////////////// */

    /// @inheritdoc ERC20
    function name() public pure override returns (string memory) {
        return "OptionZero Net-Delta Token";
    }

    /// @inheritdoc ERC20
    function symbol() public pure override returns (string memory) {
        return "ozN";
    }

    /* ///////////////////////////////////////////////////////////////
                             CONTROLLED MINT/BURN
    /////////////////////////////////////////////////////////////// */

    /// @notice Mint `amount` NTokens to `to`.
    /// @dev    Only callable by Trancher.
    /// @param  to     Recipient address.
    /// @param  amount Amount to mint, 18 decimals.
    function mint(address to, uint256 amount) external {
        if (msg.sender != trancher) revert NToken_OnlyTrancher(msg.sender);
        _mint(to, amount);
    }

    /// @notice Burn `amount` NTokens from `from`.
    /// @dev    Only callable by Trancher.
    /// @param  from   Address to burn tokens from.
    /// @param  amount Amount to burn, 18 decimals.
    function burn(address from, uint256 amount) external {
        if (msg.sender != trancher) revert NToken_OnlyTrancher(msg.sender);
        _burn(from, amount);
    }
}
