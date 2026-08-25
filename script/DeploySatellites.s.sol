// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {AssEngine} from "../src/engine/AssEngine.sol";
import {AssSwapExecutor} from "../src/adapters/AssSwapExecutor.sol";
import {AssTriggerAdapter} from "../src/adapters/AssTriggerAdapter.sol";

/// Deploys the four satellites as beacon-upgradeable proxies (audit item 3):
/// one impl + one Guardian-owned beacon per contract type, one BeaconProxy each.
/// The PROXY addresses are the canonical ENGINE/EXEC/ADAPTER from here on.
/// NOT here (postlaunch.sh territory): adapter.setVault, vault OPERATOR grant,
/// adapter routes, scheduleCycle.
contract DeploySatellites is Script {
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;

    struct Deployed {
        address engineP; address engineB;
        address execP;   address execB;
        address adapterP; address adapterB;
    }

    function _deploy(address impl, bytes memory init) internal returns (address proxy, address beacon) {
        beacon = address(new UpgradeableBeacon(impl, GUARDIAN)); // Guardian-born (no transfer to forget)
        proxy = address(new BeaconProxy(beacon, init));
    }

    function _deployAll(address deployer) internal returns (Deployed memory d) {
        (d.engineP, d.engineB) = _deploy(
            address(new AssEngine()), abi.encodeCall(AssEngine.initialize, (QQQB, deployer)));
        (d.execP, d.execB) = _deploy(
            address(new AssSwapExecutor()), abi.encodeCall(AssSwapExecutor.initialize, (QQQB, deployer)));
        (d.adapterP, d.adapterB) = _deploy(
            address(new AssTriggerAdapter()),
            abi.encodeCall(AssTriggerAdapter.initialize, (TRIGGER_SERVICE, d.engineP, WBNB, deployer)));
    }

    function _wire(Deployed memory d, address deployer) internal {
        AssEngine engine = AssEngine(d.engineP);

        // --- basket (0.5 QQQB per-buy cap per audit feedback) ---
        address[3] memory stocks = [
            0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec, // BABAB
            0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c, // TSMB
            0xCA750eF65f295BBECd685Abf54e82CAf297BDB61  // SKHYB
        ];
        uint16[3] memory weights = [uint16(3334), 3333, 3333];
        for (uint256 i; i < 3; ++i) {
            engine.addAsset(stocks[i], weights[i], 0.5 ether);
        }

        engine.setExecutor(d.execP);
        engine.setDistributor(vm.envAddress("BASKET")); // buys deliver into the IB-ASS basket
        engine.setKeeper(deployer, true);        // manual-keeper fallback mandate
        engine.setKeeper(d.adapterP, true);      // automation
        engine.setGasFund(d.adapterP, 100);      // 1% skim -> adapter gas tank
        AssSwapExecutor(d.execP).setEngine(d.engineP);
        AssSwapExecutor(d.execP).setRouter(SMART_ROUTER, true);
        AssTriggerAdapter(payable(d.adapterP)).setSwapRouter(SMART_ROUTER);
    }

    function run() external {
        address deployer = msg.sender;
        uint256 seedBnb = vm.envOr("SEED_BNB", uint256(0.05 ether)); // adapter gas tank

        vm.startBroadcast();
        Deployed memory d = _deployAll(deployer);
        _wire(d, deployer);
        if (seedBnb > 0) { (bool ok,) = d.adapterP.call{value: seedBnb}(""); require(ok, "seed failed"); }
        vm.stopBroadcast();

        console2.log("engine  proxy:", d.engineP);
        console2.log("engine  beacon:", d.engineB);
        console2.log("exec    proxy:", d.execP);
        console2.log("exec    beacon:", d.execB);
        console2.log("adapter proxy:", d.adapterP);
        console2.log("adapter beacon:", d.adapterB);
        console2.log("");
        console2.log("REMAINING (postlaunch.sh): adapter.setVault + vault OPERATOR grant to adapter");
        console2.log("REMAINING (route config):  adapter.setRoute x3 + setGasRoute (pools from staging quote logs)");
        console2.log("REMAINING (after routes):  adapter.scheduleCycle(0)");
    }
}