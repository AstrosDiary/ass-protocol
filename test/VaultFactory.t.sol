// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {AssVault} from "../src/vault/AssVault.sol";
import {AssVaultFactory} from "../src/vault/AssVaultFactory.sol";
import {IVaultFactory, IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";

contract VaultFactoryTest is Test {
    AssVault impl;
    UpgradeableBeacon beacon;
    AssVaultFactory factory;

    address constant PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;  // BSC VaultPortal
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b; // BSC Guardian
    address creator = makeAddr("creator");
    address taxToken = makeAddr("taxToken");
    address engine = makeAddr("engine");

    function setUp() public {
        vm.chainId(56); // CRITICAL: Flap bases revert UnsupportedChain on 31337
        impl = new AssVault();
        beacon = new UpgradeableBeacon(address(impl), address(this)); // -> Guardian pre-audit
        factory = new AssVaultFactory(address(beacon));
    }

    function _newVault() internal returns (AssVault v) {
        vm.prank(PORTAL);
        v = AssVault(payable(factory.newVault(taxToken, address(0), creator, "")));
    }

    function test_OnlyPortal_CanCreate() public {
        vm.expectRevert(IVaultFactory.OnlyVaultPortal.selector);
        factory.newVault(taxToken, address(0), creator, "");
    }

    function test_VaultInitialized_RolesCorrect() public {
        AssVault v = _newVault();
        assertEq(v.taxToken(), taxToken);
        assertEq(v.creator(), creator);
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), creator));
        assertTrue(v.hasRole(v.OPERATOR_ROLE(), creator));
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), GUARDIAN)); // mandate
        assertTrue(v.hasRole(v.OPERATOR_ROLE(), GUARDIAN));
    }

    function test_Implementation_IsInert() public {
        vm.expectRevert(); // InvalidInitialization: _disableInitializers worked
        impl.initialize(taxToken, creator);
    }

    function test_GuardianRole_Irrevocable_OthersRevocable() public {
        AssVault v = _newVault();
        bytes32 opRole = v.OPERATOR_ROLE();   // cache: no inner call to eat the cheatcodes

        vm.prank(creator);
        vm.expectRevert(AssVault.CannotRevokeGuardianRole.selector);
        v.revokeRole(opRole, GUARDIAN);

        address op = makeAddr("op");
        vm.startPrank(creator);               // startPrank persists — inner calls safe here
        v.grantRole(opRole, op);
        v.revokeRole(opRole, op);
        vm.stopPrank();
        assertFalse(v.hasRole(opRole, op));
    }

    function test_RevenueAndRelease_Flow() public {
        AssVault v = _newVault();
        vm.prank(creator);
        v.setEngine(engine);

        hoax(makeAddr("taxProcessor"), 5 ether);
        (bool ok,) = address(v).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(v.totalReceived(), 5 ether);
        assertEq(v.pendingBnb(), 5 ether);

        vm.prank(creator);
        v.release();
        assertEq(engine.balance, 5 ether);
        assertEq(v.totalReleased(), 5 ether);
        assertEq(v.pendingBnb(), 0);
    }

    function test_Release_GuardianCanCall_StrangerCannot() public {
        AssVault v = _newVault();
        vm.prank(creator);
        v.setEngine(engine);
        vm.deal(address(v), 1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        v.release();
        vm.prank(GUARDIAN);
        v.release(); // mandate: guardian backup path works
        assertEq(engine.balance, 1 ether);
    }

    // ---------------- launch pinning
    function _validPayload() internal pure returns (IVaultFactoryValidationV2.LaunchValidationDataV1 memory d) {
        d.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        d.quoteToken = address(0);
        d.buyTaxRate = 300;
        d.sellTaxRate = 300;
        d.vaultBps = 10_000;
        d.deflationBps = 0;
        d.dividendBps = 0;
        d.lpBps = 0;
        d.dividendToken = address(0);
        d.minimumShareBalance = 10_000e18;
    }

    function test_OnBeforeLaunch_AcceptsCanonicalProfile() public view {
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(_validPayload()));
        assertTrue(ok, reason);
    }

    function test_OnBeforeLaunch_RejectsEveryDeviation() public {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d;

        d = _validPayload(); d.buyTaxRate = 500;
        (bool ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.sellTaxRate = 0;
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.dividendBps = 100;      // not tracker-only
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.vaultBps = 9_000;       // not 100% to vault
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.minimumShareBalance = 1e18;
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.quoteToken = makeAddr("usdt");
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);
    }

    function test_DescriptionAndSchema_Respond() public {
        AssVault v = _newVault();
        assertGt(bytes(v.description()).length, 0);
        assertEq(v.vaultUISchema().methods.length, 4);
        assertEq(factory.vaultDataSchema().fields.length, 0);
        assertEq(factory.isQuoteTokenSupported(address(0)), true);
        assertEq(factory.isQuoteTokenSupported(makeAddr("usdt")), false);
    }
}