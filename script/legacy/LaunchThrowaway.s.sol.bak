// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";

/// Launches the throwaway token directly via VaultPortal, bypassing the Flap
/// UI (whose minimumShareBalance field is broken — it encodes 0 regardless of
/// input; verified from failed-tx calldata). Params mirror the UI's own
/// choices exactly, with minimumShareBalance corrected to 10,000e18.
contract LaunchThrowaway is Script {
    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant FACTORY = 0x41ed5BA0e76C96976AbCfF185abb95Bc9ea7DeD9;

    function run() external {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p;
        p.name = "BOCKS";
        p.symbol = "BOCKS";
        p.meta = "bafkreif4h6tgzmb3pexjds353wgs3olfmkrye3xncvypqcmwfwdjlmjzbe";
        p.dexThresh = IPortalCommonTypes.DexThreshType(1);  // as UI encoded        // as UI encoded
        p.salt = 0xb91e0f054fcab416b30776e71334043d1f1cdbc2ca0ef11a197bc0acd68102c3; // UI-mined vanity salt, unconsumed
        p.migratorType = IPortalTypes.MigratorType(1);      // as UI encoded
        p.quoteToken = address(0);                          // native BNB
        p.quoteAmt = 0;                                     // no dev buy in-launch; buy on curve after
        p.permitData = "";
        p.extensionID = bytes32(0);
        p.extensionData = "";
        p.dexId = IPortalTypes.DEXId(0);
        p.lpFeeProfile = IPortalTypes.V3LPFeeProfile(0);
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3153600000;                         // ~100y (Flap "forever" default)
        p.antiFarmerDuration = 2592000;                     // 30d (UI default)
        p.mktBps = 10_000;                                  // 100% remainder -> vault
        p.deflationBps = 0;
        p.dividendBps = 0;                                  // tracker-only
        p.lpBps = 0;
        p.minimumShareBalance = 10_000e18;                  // THE FIX
        p.dividendToken = address(0);
        p.commissionReceiver = address(0);
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        p.vaultFactory = FACTORY;
        p.vaultData = "";

        vm.startBroadcast();
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault(p);
        vm.stopBroadcast();
        console2.log("token:", token);
    }
}