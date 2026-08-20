// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBaseV2} from "./VaultBaseV2.sol";

/// @title VaultBaseV3
/// @author The Flap Team
/// @notice Adds ERC20 quote token support via `vaultQuoteToken()` discovery
///         and the normative balance-delta accounting model (see Flap docs).
abstract contract VaultBaseV3 is VaultBaseV2 {
    /// @notice The revenue currency this vault accounts for.
    /// @dev MUST equal the tax token's quote token; `address(0)` = native.
    ///      MUST be stable for the vault's life and MUST NOT revert.
    function vaultQuoteToken() public view virtual returns (address quoteToken);

    /// @notice Vault-side spec revision.
    function vaultSpecVersion() public pure virtual returns (string memory) {
        return "v3";
    }
}