// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
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
    address public constant REQUIRED_QUOTE = 0x205812CdBed920aFf76C6580abD681a46D11efc7; // QQQB

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);

    constructor(address beacon_) {
        require(beacon_ != address(0), "ASS: zero beacon");
        beacon = beacon_;
    }

    /// @dev v2.3: the gate VaultPortal checks before allowing ERC20-quote launches.
    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
    }

    /// @inheritdoc VaultFactoryBaseV2
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Deploys a multi-reward-token tax vault: tax revenue (QQQB) accumulates here and is "
            "converted by an engine into a basket of reward tokens distributed to holders - built "
            "because Flap natively supports only a single dividend token per launch, while this "
            "design distributes several (e.g. Asian Stock Strategy pays holders in 3 tokenized "
            "equities: BABAB, TSMB, SKHYB). NOTE: the vault arrives unwired - after launch the "
            "creator must deploy and connect their own engine + distributor (vault.setEngine), "
            "then register their chosen reward tokens. vaultData is ignored.";
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
        require(quoteToken == REQUIRED_QUOTE, "ASS: QQQB quote only");

        vault = address(new BeaconProxy(
            beacon,
            abi.encodeCall(AssVault.initialize, (taxToken, creator))
        ));
        emit VaultCreated(vault, taxToken, creator);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == REQUIRED_QUOTE; // QQQB pair only
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
        if (d.quoteToken != REQUIRED_QUOTE) return (false, "quote token must be QQQB");
        if (d.buyTaxRate + d.sellTaxRate == 0) return (false, "a non-zero trade tax is required (the vault's only revenue source)");
        if (d.vaultBps == 0) return (false, "vaultBps must be > 0 (some tax share must reach the vault)");
        if (d.dividendBps != 0) return (false, "dividendBps must be 0 (tracker-only mode; the distributor pushes rewards manually)");
        return (true, "");
    }

    /// @dev informational mirror of _validateBeforeLaunch for the launch UI
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory p) {
        p = new FactoryPolicy[](5);
        p[0] = FactoryPolicy("quoteToken", "eq", abi.encode(REQUIRED_QUOTE), "Quote token must be QQQB (Invesco QQQ Trust bStock).");
        p[1] = FactoryPolicy("buyTaxRate", "gte", abi.encode(uint256(0)), "Buy + sell tax must be non-zero in total - tax is the vault's only revenue source.");
        p[2] = FactoryPolicy("sellTaxRate", "gte", abi.encode(uint256(0)), "See buyTaxRate - at least one of the two taxes must be non-zero.");
        p[3] = FactoryPolicy("vaultBps", "gt", abi.encode(uint256(0)), "Some share of tax must route to the vault.");
        p[4] = FactoryPolicy("dividendBps", "eq", abi.encode(uint256(0)), "Dividends run in tracker-only mode; the vault's distributor pushes rewards each cycle.");
    }
}