// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {AssVault} from "../src/vault/AssVault.sol";
import {AssVaultFactory} from "../src/vault/AssVaultFactory.sol";
import {AssEngine} from "../src/engine/AssEngine.sol";
import {AssSwapExecutor} from "../src/adapters/AssSwapExecutor.sol";
import {AssDistributor} from "../src/distributor/AssDistributor.sol";

/// Deploys the full pre-launch stack. NOT deployed here:
///  - AssVault proxy (the Flap VaultPortal creates it during token launch)
///  - AssViews (needs the tracker address, which exists only after launch)
contract Deploy is Script {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // canonical BSC WBNB

    function run() external {
        address deployer = msg.sender;
        
        vm.startBroadcast();

        AssVault impl = new AssVault();
        // beacon owner = deployer for the throwaway; -> Flap Guardian pre-audit on the real run
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), deployer);
        AssVaultFactory factory = new AssVaultFactory(address(beacon));

        AssEngine engine = new AssEngine(WBNB, deployer);
        AssSwapExecutor exec = new AssSwapExecutor(WBNB, deployer);
        AssDistributor dist = new AssDistributor(deployer);

        // --- basket, verified against Binance collateral data pre-deploy ---
        address[3] memory stocks = [
            0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec, // BABAB
            0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c, // TSMB
            0xCA750eF65f295BBECd685Abf54e82CAf297BDB61 // SKHYB
        ];
        uint16[3] memory weights = [uint16(3334), 3333, 3333]; // sums to 10_000
        for (uint256 i; i < 3; ++i) {
            engine.addAsset(stocks[i], weights[i], 25 ether); // per-buy cap: revisit units in QQQB pass
            dist.addAsset(stocks[i]);
        }

        // wiring that doesn't need the token
        engine.setExecutor(address(exec));
        engine.setDistributor(address(dist));
        engine.setKeeper(deployer, true);
        exec.setEngine(address(engine));
        dist.setKeeper(deployer, true);

        vm.stopBroadcast();

        console2.log("impl:        ", address(impl));
        console2.log("beacon:      ", address(beacon));
        console2.log("factory:     ", address(factory));
        console2.log("engine:      ", address(engine));
        console2.log("executor:    ", address(exec));
        console2.log("distributor: ", address(dist));
        console2.log("");
        console2.log("NEXT: launch throwaway token at flap.sh/launch?vaultfactory=", address(factory));
    }
}