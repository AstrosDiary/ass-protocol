// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";

/// Launches the REAL $ASS token via VaultPortal — never the Flap UI form
/// (its minimumShareBalance field silently encodes 0; factory would reject,
/// but the script path is the rehearsed, deterministic one).
/// PRE-LAUNCH (runbook Phase 2): fill the Flap UI form with real identity and
/// QQQB as payment token, CANCEL AT THE WALLET, then lift from the attempted
/// calldata: the metadata CID, the mined salt, and (verify) enum encodings.
/// DEV BUY: quoteAmt is denominated in QQQB — the deployer must hold it AND
/// approve the VaultPortal to pull it before running (ERC20 quote = transferFrom).
contract LaunchAss is Script {
    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;

    address constant FACTORY = address(0);      // <- FILL: DeployCore output
    string constant META_CID = "";              // <- FILL: from UI-mined calldata
    bytes32 constant SALT = bytes32(0);         // <- FILL: from UI-mined calldata
    uint256 constant DEV_BUY_QQQB = 0;          // <- FILL (or leave 0 for no in-launch dev buy)

    function run() external {
        require(FACTORY != address(0), "FILL: FACTORY");
        require(bytes(META_CID).length > 0, "FILL: META_CID");
        require(SALT != bytes32(0), "FILL: SALT");

        IVaultPortalTypes.NewTokenV6WithVaultParams memory p;
        p.name = "Asian Stock Strategy";
        p.symbol = "ASS";
        p.meta = META_CID;
        p.dexThresh = IPortalCommonTypes.DexThreshType(1);  // verify vs UI-mined calldata for QQQB pair
        p.salt = SALT;
        p.migratorType = IPortalTypes.MigratorType(1);      // verify vs UI-mined calldata
        p.quoteToken = QQQB;                                // THE PAIRING
        p.quoteAmt = DEV_BUY_QQQB;
        p.permitData = "";
        p.extensionID = bytes32(0);
        p.extensionData = "";
        p.dexId = IPortalTypes.DEXId(0);                    // verify vs UI-mined calldata
        p.lpFeeProfile = IPortalTypes.V3LPFeeProfile(0);    // verify vs UI-mined calldata
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3153600000;                         // ~100y (forever)
        p.antiFarmerDuration = 2592000;                     // 30d
        p.mktBps = 10_000;                                  // 100% remainder -> vault
        p.deflationBps = 0;
        p.dividendBps = 0;                                  // tracker-only
        p.lpBps = 0;
        p.minimumShareBalance = 10_000e18;                  // exact-match pinned by factory
        p.dividendToken = address(0);
        p.commissionReceiver = address(0);
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        p.vaultFactory = FACTORY;
        p.vaultData = "";

        vm.startBroadcast();
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault(p);
        vm.stopBroadcast();
        console2.log("$ASS token:", token);
    }
}