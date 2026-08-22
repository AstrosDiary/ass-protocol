// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {AssVault} from "../src/vault/AssVault.sol";
import {AssVaultFactory} from "../src/vault/AssVaultFactory.sol";

/// Vault stack only (impl + beacon + factory). Satellites: DeploySatellites.s.sol.
/// Beacon is born Guardian-owned — no transfer step to forget.
contract DeployCore is Script {
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b; // BSC

    function run() external {
        vm.startBroadcast();
        AssVault impl = new AssVault();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), GUARDIAN);
        AssVaultFactory factory = new AssVaultFactory(address(beacon));
        vm.stopBroadcast();

        console2.log("vault impl:  ", address(impl));
        console2.log("vault beacon:", address(beacon), "(owner: Guardian)");
        console2.log("factory:     ", address(factory));
    }
}