// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {VaultFactoryBaseV2} from "../flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "../flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "../flap/IVaultSchemasV1.sol";
import {IPortalTypes} from "../flap/IPortal.sol";
import {AssVault} from "./AssVault.sol";

/// @title AssVaultFactory — deploys AssVault beacon proxies via Flap VaultPortal
/// @notice Factory spec v2.2. Every vault is a BeaconProxy against a shared
/// UpgradeableBeacon (upgrade authority: Flap Guardian, per audit spec).
/// onBeforeLaunch pins the exact $ASS launch configuration on-chain so a
/// misconfigured launch reverts at the portal.
contract AssVaultFactory is VaultFactoryBaseV2 {
    address public immutable beacon;

    /// @dev the exact launch profile this factory permits
    uint16 public constant REQUIRED_BUY_TAX = 300;   // 3%
    uint16 public constant REQUIRED_SELL_TAX = 300;  // 3%
    uint256 public constant REQUIRED_MIN_SHARE = 10_000e18; // 10,000 $ASS
    uint16 public constant REQUIRED_VAULT_BPS = 10_000;     // 100% of tax remainder -> vault

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);

    constructor(address beacon_) {
        require(beacon_ != address(0), "ASS: zero beacon");
        beacon = beacon_;
    }

    /// @inheritdoc VaultFactoryBaseV2
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Asian Stock Strategy vault: accumulates tax BNB and converts it into a basket of "
            "Asian bStocks distributed to holders. No configurable parameters - vaultData is ignored.";
        schema.fields = new FieldDescriptor[](0);
        schema.isArray = false;
    }

    function newVault(address taxToken, address quoteToken, address creator, bytes calldata)
        external
        override
        returns (address vault)
    {
        if (msg.sender != _getVaultPortal()) revert OnlyVaultPortal();
        if (taxToken == address(0) || creator == address(0)) revert ZeroAddress();
        require(quoteToken == address(0), "ASS: BNB quote only");

        vault = address(new BeaconProxy(
            beacon,
            abi.encodeCall(AssVault.initialize, (taxToken, creator))
        ));
        emit VaultCreated(vault, taxToken, creator);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0); // native BNB pair only
    }

    /// @dev v2.2 normalized validation: the ONLY launch this factory accepts
    /// is the canonical $ASS profile. Tracker-only dividends (bps 0) with the
    /// full tax remainder routed to the vault.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory d)
        internal
        pure
        override
        returns (bool, string memory)
    {
        if (d.tokenVersion != IPortalTypes.TokenVersion.TOKEN_TAXED_V3) return (false, "tokenVersion must be TOKEN_TAXED_V3");
        if (d.quoteToken != address(0)) return (false, "quote token must be native BNB");
        if (d.buyTaxRate != REQUIRED_BUY_TAX) return (false, "buy tax must be 3% (300 bps)");
        if (d.sellTaxRate != REQUIRED_SELL_TAX) return (false, "sell tax must be 3% (300 bps)");
        if (d.vaultBps != REQUIRED_VAULT_BPS) return (false, "vault must receive 100% of tax remainder");
        if (d.deflationBps != 0) return (false, "deflation must be 0");
        if (d.dividendBps != 0) return (false, "dividendBps must be 0 (tracker-only mode)");
        if (d.lpBps != 0) return (false, "lpBps must be 0");
        if (d.minimumShareBalance != REQUIRED_MIN_SHARE) return (false, "minimumShareBalance must be 10,000 ASS");
        return (true, "");
    }

    /// @dev informational mirror of _validateBeforeLaunch for the launch UI
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory p) {
        p = new FactoryPolicy[](6);
        p[0] = FactoryPolicy("quoteToken", "eq", abi.encode(address(0)), "Quote token must be native BNB.");
        p[1] = FactoryPolicy("buyTaxRate", "eq", abi.encode(uint256(REQUIRED_BUY_TAX)), "Buy tax must be 3%.");
        p[2] = FactoryPolicy("sellTaxRate", "eq", abi.encode(uint256(REQUIRED_SELL_TAX)), "Sell tax must be 3%.");
        p[3] = FactoryPolicy("dividendBps", "eq", abi.encode(uint256(0)), "Dividends run in tracker-only mode (bps 0).");
        p[4] = FactoryPolicy("mktBps", "eq", abi.encode(uint256(REQUIRED_VAULT_BPS)), "100% of tax remainder routes to the vault.");
        p[5] = FactoryPolicy("minimumShareBalance", "eq", abi.encode(REQUIRED_MIN_SHARE), "Minimum eligible balance is 10,000 ASS.");
    }
}