// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AssViews} from "../src/views/AssViews.sol";

contract DeployViews is Script {
    function run() external {
        vm.startBroadcast();
        AssViews views = new AssViews(
            0x66A090818e449Dc542EEe8872b90Bed195103b48,          // vault
            payable(0x57292Ce4ca3863e8E61986C038678296E91b6736), // engine
            0xF9F57A1f85af621aF8c3a0c2Ae8fE9bb1D6eA875,          // distributor
            0x8E82CfeB56993066289c9DBDB737c36183c33706           // tracker
        );
        vm.stopBroadcast();
        console2.log("views:", address(views));
    }
}