// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title  PToken — OptionZero Principal / Safe Tranche Token
/// @author OptionZero
/// @notice ERC-20 token representing the USD-pegged, senior tranche of an
///         OptionZero vault deposit. The P tranche's value is maintained via
///         accounting-level soft peg inside Vault: the vault always ensures
///         that the wstETH backing the P supply covers at least 1 USD per token
///         before the N tranche absorbs losses.
///
/// @dev    Mint and burn are restricted to the Trancher contract set at
///         construction time. There is no admin key, no rebasing, and no
///         supply cap — supply tracks vault deposits exactly.
///
///         Token has 18 decimals. 1 PToken ≈ 1 USD of wstETH collateral at
///         time of issuance; the exact redemption value is computed by Vault.
contract PToken is ERC20 {
    /* ///////////////////////////////////////////////////////////////
                                 STORAGE
    /////////////////////////////////////////////////////////////// */

    /// @notice Address of the Trancher contract authorised to mint/burn.
    address public immutable trancher;

    /* ///////////////////////////////////////////////////////////////
                                  ERRORS
    /////////////////////////////////////////////////////////////// */

    /// @dev Reverts when caller is not the authorised Trancher.
    error PToken_OnlyTrancher(address caller);

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
        return "OptionZero Principal Token";
    }

    /// @inheritdoc ERC20
    function symbol() public pure override returns (string memory) {
        return "ozP";
    }

    /* ///////////////////////////////////////////////////////////////
                             CONTROLLED MINT/BURN
    /////////////////////////////////////////////////////////////// */

    /// @notice Mint `amount` PTokens to `to`.
    /// @dev    Only callable by Trancher.
    /// @param  to     Recipient address.
    /// @param  amount Amount to mint, 18 decimals.
    function mint(address to, uint256 amount) external {
        if (msg.sender != trancher) revert PToken_OnlyTrancher(msg.sender);
        _mint(to, amount);
    }

    /// @notice Burn `amount` PTokens from `from`.
    /// @dev    Only callable by Trancher. Trancher is trusted to validate
    ///         balances before calling; no ERC-20 allowance check is required
    ///         because Trancher IS the protocol authority for P/N lifecycle.
    /// @param  from   Address to burn tokens from.
    /// @param  amount Amount to burn, 18 decimals.
    function burn(address from, uint256 amount) external {
        if (msg.sender != trancher) revert PToken_OnlyTrancher(msg.sender);
        _burn(from, amount);
    }
}
