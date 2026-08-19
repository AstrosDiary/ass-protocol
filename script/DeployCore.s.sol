// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {AssVault} from "../src/vault/AssVault.sol";
import {AssVaultFactory} from "../src/vault/AssVaultFactory.sol";
import {AssEngine} from "../src/engine/AssEngine.sol";
import {AssSwapExecutor} from "../src/adapters/AssSwapExecutor.sol";
import {AssDistributor} from "../src/distributor/AssDistributor.sol";

/// Deploys the full pre-launch stack for the QQQB-paired $ASS.
/// NOT deployed here:
///  - AssVault proxy (the Flap VaultPortal creates it during token launch)
///  - AssViews (needs the tracker address, which exists only after launch)
contract DeployCore is Script {
    address constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7; // Invesco QQQ Trust bStock
    address constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4; // Pancake SmartRouter V3

    function run() external {
        address deployer = msg.sender;

        vm.startBroadcast();

        AssVault impl = new AssVault();
        // beacon owner = deployer; -> Flap Guardian transfer with the audit/badge submission
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), deployer);
        AssVaultFactory factory = new AssVaultFactory(address(beacon));

        AssEngine engine = new AssEngine(QQQB, deployer);
        AssSwapExecutor exec = new AssSwapExecutor(QQQB, deployer);
        AssDistributor dist = new AssDistributor(deployer);

        // --- basket, verified against Binance collateral data pre-deploy ---
        address[3] memory stocks = [
            0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec, // BABAB
            0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c, // TSMB
            0xCA750eF65f295BBECd685Abf54e82CAf297BDB61  // SKHYB
        ];
        uint16[3] memory weights = [uint16(3334), 3333, 3333]; // sums to 10_000
        for (uint256 i; i < 3; ++i) {
            engine.addAsset(stocks[i], weights[i], 2 ether); // 2 QQQB/buy cap (~$1.2k) — tune post-launch
            dist.addAsset(stocks[i]);
        }

        // wiring that doesn't need the token
        engine.setExecutor(address(exec));
        engine.setDistributor(address(dist));
        engine.setKeeper(deployer, true);
        exec.setEngine(address(engine));
        exec.setRouter(SMART_ROUTER, true); // allowlist baked at deploy — no post-step to forget
        dist.setKeeper(deployer, true);

        vm.stopBroadcast();

        console2.log("impl:        ", address(impl));
        console2.log("beacon:      ", address(beacon));
        console2.log("factory:     ", address(factory));
        console2.log("engine:      ", address(engine));
        console2.log("executor:    ", address(exec));
        console2.log("distributor: ", address(dist));
        console2.log("");
        console2.log("NEXT: metadata trick at flap.sh (QQQB payment token) -> LaunchAss.s.sol; factory:", address(factory));
    }
}