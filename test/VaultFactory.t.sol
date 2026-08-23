// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {AssVault} from "../src/vault/AssVault.sol";
import {AssVaultFactory} from "../src/vault/AssVaultFactory.sol";
import {IVaultFactory, IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {MockBStock} from "./mocks/MockBStock.sol";
import {FactoryPolicy} from "../src/flap/IVaultSchemasV1.sol";

/// Minimal ERC20 etched at the real QQQB address so the vault's hardcoded
/// QUOTE constant resolves against controllable code in tests.
contract MockQuote {
    string public constant symbol = "QQQB";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt;
        return true;
    }
}

contract VaultFactoryTest is Test {
    AssVault impl;
    UpgradeableBeacon beacon;
    AssVaultFactory factory;
    MockQuote qqqb;

    address constant PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;  // BSC VaultPortal
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b; // BSC Guardian
    address constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;    // Invesco QQQ Trust bStock
    address constant MAGIC_DIVIDEND_COMPUTED = 0xC0Dec0dec0DeC0Dec0dEc0DEC0DEC0DEC0DEC0dE;
    address basketStub;
    address creator = makeAddr("creator");
    address taxToken = makeAddr("taxToken");
    address engine = makeAddr("engine");

    function setUp() public {
        vm.chainId(56); // CRITICAL: Flap bases revert UnsupportedChain on 31337
        deployCodeTo("test/VaultFactory.t.sol:MockQuote", QQQB); // mock lives at the REAL quote address
        qqqb = MockQuote(QQQB);
        impl = new AssVault();
        beacon = new UpgradeableBeacon(address(impl), address(this)); // -> Guardian pre-audit
        basketStub = address(new MockBStock());
        factory = new AssVaultFactory(address(beacon), basketStub);
    }

    function _newVault() internal returns (AssVault v) {
        vm.prank(PORTAL);
        v = AssVault(payable(factory.newVault(taxToken, QQQB, creator, "")));
    }

    function test_OnlyPortal_CanCreate() public {
        vm.expectRevert(IVaultFactory.OnlyVaultPortal.selector);
        factory.newVault(taxToken, QQQB, creator, "");
    }

    function test_Portal_CannotCreate_WithWrongQuote() public {
        vm.prank(PORTAL);
        vm.expectRevert(bytes("ASS: QQQB quote only"));
        factory.newVault(taxToken, address(0), creator, ""); // BNB pairing now refused
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

        // tax arrives as a plain ERC20 transfer (TaxProcessor dispatch)
        qqqb.mint(address(v), 5 ether);
        assertEq(v.totalReceived(), 5 ether);
        assertEq(v.pendingQuote(), 5 ether);

        vm.prank(creator);
        v.release();
        assertEq(qqqb.balanceOf(engine), 5 ether);
        assertEq(v.totalReleased(), 5 ether);
        assertEq(v.pendingQuote(), 0);
        assertEq(v.totalReceived(), 5 ether); // received == released + pending, still true
    }

    function test_NativeBnb_Reverts() public {
        AssVault v = _newVault();
        hoax(makeAddr("stray"), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertFalse(ok); // no receive/fallback: vault can only ever hold QQQB
    }

    function test_Release_GuardianCanCall_StrangerCannot() public {
        AssVault v = _newVault();
        vm.prank(creator);
        v.setEngine(engine);
        qqqb.mint(address(v), 1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        v.release();
        vm.prank(GUARDIAN);
        v.release(); // mandate: guardian backup path works
        assertEq(qqqb.balanceOf(engine), 1 ether);
    }

    // ---------------- launch pinning
    function _validPayload() internal pure returns (IVaultFactoryValidationV2.LaunchValidationDataV1 memory d) {
        d.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        d.quoteToken = QQQB;
        d.buyTaxRate = 300;
        d.sellTaxRate = 300;
        d.vaultBps = 10_000;
        d.deflationBps = 0;
        d.dividendBps = 0;
        d.lpBps = 0;
        d.dividendToken = MAGIC_DIVIDEND_COMPUTED;
    }

    function test_OnBeforeLaunch_AcceptsCanonicalProfile() public view {
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(_validPayload()));
        assertTrue(ok, reason);
    }

    /// relaxation proof: a third-party profile (different taxes, split bps,
    /// no min share) is launchable through this factory
    function test_OnBeforeLaunch_AcceptsRelaxedThirdPartyProfile() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d = _validPayload();
        d.buyTaxRate = 500;
        d.sellTaxRate = 100;
        d.vaultBps = 6_000;          // splits allowed
        d.lpBps = 4_000;
        d.minimumShareBalance = 0;   // UI-encoded launches pass
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(d));
        assertTrue(ok, reason);
    }

    function test_OnBeforeLaunch_RejectsEveryDeviation() public {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d;
        bool ok;

        d = _validPayload(); d.buyTaxRate = 0; d.sellTaxRate = 0; // zero total tax = no revenue, ever
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.vaultBps = 0;            // nothing routed to the vault
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.dividendBps = 100;       // not tracker-only
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.quoteToken = address(0); // BNB pairing rejected
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.quoteToken = makeAddr("usdt"); // any other ERC20 rejected
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.dividendToken = address(0);          // sentinel is mandatory
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);

        d = _validPayload(); d.dividendToken = makeAddr("some-token"); // even a real-looking token
        (ok,) = factory.onBeforeLaunch(abi.encode(d)); assertFalse(ok);
    }

    function test_V3_PingRecognizesRevenue_ZeroDeltaNoOp() public {
        AssVault v = _newVault();
        assertEq(v.vaultQuoteToken(), QQQB);
        qqqb.mint(address(v), 3 ether);
        (bool ok,) = address(v).call{value: 0}("");   // the TaxProcessor ping
        assertTrue(ok);
        assertEq(v.accountedQuote(), 3 ether);
        (ok,) = address(v).call{value: 0}("");        // spurious ping: silent no-op
        assertTrue(ok);
        assertEq(v.accountedQuote(), 3 ether);
        vm.prank(creator); v.setEngine(engine);
        vm.prank(creator); v.release();
        assertEq(v.accountedQuote(), 0);              // rule 3: baseline decremented — no deadlock
    }

    function test_DescriptionAndSchema_Respond() public {
        AssVault v = _newVault();
        assertGt(bytes(v.description()).length, 0);
        assertEq(v.vaultUISchema().methods.length, 5);
        assertEq(factory.vaultDataSchema().fields.length, 0);
        assertEq(factory.isQuoteTokenSupported(QQQB), true);
        assertEq(factory.isQuoteTokenSupported(address(0)), false); // BNB no longer supported
        assertEq(factory.isQuoteTokenSupported(makeAddr("usdt")), false);
    }

    /// v2.3 computed-dividend resolution (docs: lp-token-as-dividend): the
    /// portal staticcalls this at launch and substitutes the result for the
    /// MAGIC_DIVIDEND_COMPUTED sentinel — this is how the basket gets wired
    /// in the launch tx itself, with no post-launch call.
    function test_ResolveDividendToken_ReturnsBasket() public view {
        assertEq(factory.resolveDividendToken(address(0xBEEF), 6, ""), basketStub);
        assertEq(factory.BASKET(), basketStub);
    }

    function test_Policies_DeclareComputedDividend() public view {
        // p[5] backs the on-chain sentinel pin (policies are UI-advisory only)
        FactoryPolicy[] memory p = factory.tokenCreationPolicies();
        assertEq(p.length, 6);
        assertEq(p[5].target, "dividendToken");
        assertEq(abi.decode(p[5].value, (address)), MAGIC_DIVIDEND_COMPUTED);
    }
}