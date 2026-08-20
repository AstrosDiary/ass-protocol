// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AssViews} from "../src/views/AssViews.sol";

/// Deploys AssViews v2 against a live $ASS deployment. Run AFTER launch +
/// wiring (runbook Phase 3): the vault proxy and tracker exist only once the
/// VaultPortal has created the token.
/// FILL all four addresses from the current deployment — the script reverts
/// until every one is set, so a stale run cannot half-fire.
contract DeployViews is Script {
    address constant VAULT = address(0xA823c0B59fC26CE6F5e238dd8a24ae935042f3b2);        // <- FILL: vault proxy (VaultCreated event / token launch)
    address constant ENGINE = address(0x96bcC93d57e39BA5509f81eA89c8efd4ce70d4e6);       // <- FILL: DeployCore output
    address constant DISTRIBUTOR = address(0x05cfBc7E590c95F272Db8796D7d8c3cDC79920A2);  // <- FILL: DeployCore output
    address constant TRACKER = address(0xae11E7f561d5452BE6a390f122abeB5AB50551Fc);      // <- FILL: token.dividendContract()

    function run() external {
        require(VAULT != address(0), "FILL: VAULT");
        require(ENGINE != address(0), "FILL: ENGINE");
        require(DISTRIBUTOR != address(0), "FILL: DISTRIBUTOR");
        require(TRACKER != address(0), "FILL: TRACKER");

        vm.startBroadcast();
        AssViews views = new AssViews(VAULT, ENGINE, DISTRIBUTOR, TRACKER);
        vm.stopBroadcast();
        console2.log("views:", address(views));
    }
}