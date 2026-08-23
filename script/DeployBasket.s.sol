// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {AssBasket} from "../src/basket/AssBasket.sol";

/// Deploys the IB-ASS basket as the fifth Guardian-beaconed satellite.
/// Initialized with the three components, their Atlas feed ids, and the
/// Atlas PriceHub. NOT here (launch-coupled, postlaunch.sh): setTaxToken,
/// engine.setDistributor(basket).
contract DeployBasket is Script {
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant ATLAS_HUB = 0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa;

    address constant BABAB = 0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec;
    address constant TSMB  = 0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c;
    address constant SKHYB = 0xCA750eF65f295BBECd685Abf54e82CAf297BDB61;

    function run() external {
        address deployer = msg.sender;

        address[] memory subset = new address[](3);
        subset[0] = BABAB; subset[1] = TSMB; subset[2] = SKHYB;
        bytes4[] memory feedIds = new bytes4[](3);
        feedIds[0] = 0x000003c2; // BABAB feed 962
        feedIds[1] = 0x000003c8; // TSMB  feed 968
        feedIds[2] = 0x000003be; // SKHYB feed 958

        vm.startBroadcast();
        AssBasket impl = new AssBasket();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), GUARDIAN); // Guardian-born
        AssBasket basket = AssBasket(address(new BeaconProxy(
            address(beacon),
            abi.encodeCall(AssBasket.initialize, (subset, feedIds, ATLAS_HUB, deployer))
        )));
        vm.stopBroadcast();

        console2.log("basket impl:  ", address(impl));
        console2.log("basket beacon:", address(beacon), "(owner: Guardian)");
        console2.log("basket proxy: ", address(basket));
        console2.log("");
        console2.log("sanity (run now):");
        console2.log("  oracleDecimals should be 18; getSubset length 3");
        console2.log("REMAINING (launch-coupled): basket.setTaxToken(TOKEN); engine.setDistributor(basket)");
    }
}