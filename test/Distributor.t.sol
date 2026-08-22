// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssDistributor} from "../src/distributor/AssDistributor.sol";
import {MockFlapDividend} from "./mocks/MockFlapDividend.sol";
import {MockBStock} from "./mocks/MockBStock.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract DistributorTest is Test {
    AssDistributor dist;
    MockFlapDividend tracker;
    MockBStock stockA;
    MockBStock stockB;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    // sorted ascending by construction below
    address h1; address h2; address h3;

    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new BeaconProxy(address(new UpgradeableBeacon(impl, address(this))), init));
    }

    function setUp() public {
        vm.chainId(56); // guardian chain-map needs a mapped chain

        dist = AssDistributor(_proxy(address(new AssDistributor()), abi.encodeCall(AssDistributor.initialize, (owner))));
        tracker = new MockFlapDividend();
        stockA = new MockBStock();
        stockB = new MockBStock();

        vm.startPrank(owner);
        dist.setKeeper(keeper, true);
        dist.setDividendTracker(address(tracker));
        dist.addAsset(address(stockA));
        dist.addAsset(address(stockB));
        vm.stopPrank();

        // deterministic ascending addresses
        h1 = address(0x1000); h2 = address(0x2000); h3 = address(0x3000);
        tracker.setShare(h1, 100_000e18);
        tracker.setShare(h2, 300_000e18);
        tracker.setShare(h3, 600_000e18); // total 1,000,000e18
    }

    function _fullCycle(uint256 potA, uint256 potB) internal {
        stockA.mint(address(dist), potA);
        stockB.mint(address(dist), potB);
        vm.startPrank(keeper);
        dist.startCycle();
        address[] memory hs = new address[](3);
        hs[0] = h1; hs[1] = h2; hs[2] = h3;
        dist.submitHolders(hs);
        dist.finalizeSnapshot();
        dist.pushPayouts(100);
        vm.stopPrank();
    }

    // ---------------- happy path: pro-rata to the wei
    function test_ProRataDistribution() public {
        _fullCycle(1_000e18, 500e18);
        assertEq(stockA.balanceOf(h1), 100e18);  // 10%
        assertEq(stockA.balanceOf(h2), 300e18);  // 30%
        assertEq(stockA.balanceOf(h3), 600e18);  // 60%
        assertEq(stockB.balanceOf(h3), 300e18);
        assertEq(uint8(dist.phase()), 0); // back to Idle
    }

    // ---------------- flash guard: min(snapshot, live)
    function test_FlashGuard_ShareDropBetweenSnapshotAndPayout() public {
        stockA.mint(address(dist), 1_000e18);
        vm.startPrank(keeper);
        dist.startCycle();
        address[] memory hs = new address[](3);
        hs[0] = h1; hs[1] = h2; hs[2] = h3;
        dist.submitHolders(hs);
        dist.finalizeSnapshot();
        vm.stopPrank();

        tracker.setShare(h3, 0); // h3 dumps everything post-snapshot
        vm.prank(keeper);
        dist.pushPayouts(100);

        assertEq(stockA.balanceOf(h3), 0);       // paid on live=0, not snap
        assertEq(stockA.balanceOf(h1), 100e18);  // others unchanged (denominator = snapshot)
        // h3's forfeited 600e18 stays in balance -> next cycle's pot
        assertGe(stockA.balanceOf(address(dist)), 600e18);
    }

    function test_FlashGuard_ShareIncreaseCapped() public {
        stockA.mint(address(dist), 1_000e18);
        vm.startPrank(keeper);
        dist.startCycle();
        address[] memory hs = new address[](3);
        hs[0] = h1; hs[1] = h2; hs[2] = h3;
        dist.submitHolders(hs);
        dist.finalizeSnapshot();
        vm.stopPrank();

        tracker.setShare(h1, 10_000_000e18); // buys huge post-snapshot
        vm.prank(keeper);
        dist.pushPayouts(100);
        assertEq(stockA.balanceOf(h1), 100e18); // capped at snapshot share
    }

    // ---------------- keeper cannot forge, duplicate, or under-cover
    function test_RevertWhen_NotAscending() public {
        vm.startPrank(keeper);
        dist.startCycle();
        address[] memory hs = new address[](2);
        hs[0] = h2; hs[1] = h1;
        vm.expectRevert(AssDistributor.NotAscending.selector);
        dist.submitHolders(hs);
        vm.stopPrank();
    }

    function test_RevertWhen_DuplicateAcrossBatches() public {
        vm.startPrank(keeper);
        dist.startCycle();
        address[] memory hs = new address[](1);
        hs[0] = h2;
        dist.submitHolders(hs);
        vm.expectRevert(AssDistributor.NotAscending.selector);
        dist.submitHolders(hs); // same again
        vm.stopPrank();
    }

    function test_RevertWhen_CoverageTooLow() public {
        vm.startPrank(keeper);
        dist.startCycle();
        address[] memory hs = new address[](1);
        hs[0] = h1; // 10% of totalShares < 90% required
        dist.submitHolders(hs);
        vm.expectRevert();
        dist.finalizeSnapshot();
        vm.stopPrank();
    }

    // ---------------- dust accrual + flush + claim
    function test_DustAccruesBelowMinPayout_ThenFlushes() public {
        vm.prank(keeper);
        dist.setMinPayout(address(stockA), 500e18);

        _fullCycle(1_000e18, 0);
        // h1 owed 100 < 500 -> accrued, not sent
        assertEq(stockA.balanceOf(h1), 0);
        assertEq(dist.accrued(address(stockA), h1), 100e18);
        assertEq(dist.reservedForAccrued(address(stockA)), 100e18 + 300e18); // h2 also below

        // four more cycles bring h1 to exactly the 500e18 gate on cycle 5 -> pays
        for (uint256 i; i < 4; ++i) _fullCycle(1_000e18, 0);
        assertEq(stockA.balanceOf(h1), 500e18);              // paid in full at the gate
        assertEq(dist.accrued(address(stockA), h1), 0);       // ledger cleared
    }

    function test_ClaimAccrued_AnySize() public {
        vm.prank(keeper);
        dist.setMinPayout(address(stockA), 500e18);
        _fullCycle(1_000e18, 0);
        vm.prank(h1);
        dist.claimAccrued(address(stockA));
        assertEq(stockA.balanceOf(h1), 100e18); // holder's own gas, no gate
        assertEq(dist.reservedForAccrued(address(stockA)), 300e18);
    }

    // ---------------- _trySend: restricted recipients never brick a batch
    function test_RestrictedRecipient_ReAccruesAndBatchSurvives() public {
        stockA.setRestricted(h2, true); // reverter
        _fullCycle(1_000e18, 0);
        assertEq(stockA.balanceOf(h1), 100e18);       // batch survived
        assertEq(stockA.balanceOf(h2), 0);
        assertEq(dist.accrued(address(stockA), h2), 300e18); // waiting, not lost
        assertEq(stockA.balanceOf(h3), 600e18);

        stockA.setRestricted(h2, false);              // restriction lifts
        dist.flushAccrued(address(stockA), h2);       // permissionless
        assertEq(stockA.balanceOf(h2), 300e18);
    }

    function test_SoftFailRecipient_SameTreatment() public {
        stockA.setSoftFail(h2, true); // false-returner
        _fullCycle(1_000e18, 0);
        assertEq(dist.accrued(address(stockA), h2), 300e18);
        assertEq(stockA.balanceOf(h3), 600e18);
    }

    // ---------------- BEP-677: multiplier moves, raw accounting doesn't
    function test_MultiplierChange_RawPayoutsUnaffected() public {
        stockA.setMultiplier(2e18); // 2:1 corporate action mid-flight
        _fullCycle(1_000e18, 0);
        assertEq(stockA.balanceOf(h1), 100e18);           // raw, exactly as before
        assertEq(stockA.scaledBalanceOf(h1), 200e18);     // display doubles — UI's problem
    }

    // ---------------- pot integrity
    function test_PotExcludesReserved() public {
        vm.prank(keeper);
        dist.setMinPayout(address(stockA), 500e18);
        _fullCycle(1_000e18, 0); // 400e18 now reserved (h1+h2 accrued)

        uint256 reserved = dist.reservedForAccrued(address(stockA));
        stockA.mint(address(dist), 1_000e18);
        vm.startPrank(keeper);
        dist.startCycle();
        address[] memory hs = new address[](3);
        hs[0] = h1; hs[1] = h2; hs[2] = h3;
        dist.submitHolders(hs);
        dist.finalizeSnapshot();
        // new pot = balance - reserved: reserved dust is never double-spent
        assertEq(dist.cyclePot(dist.cycleId(), address(stockA)),
                 stockA.balanceOf(address(dist)) - reserved);
        vm.stopPrank();
    }

    // ---------------- asset lifecycle + sweep bar
    function test_DisabledAsset_AccruedStillClaimable() public {
        vm.prank(keeper);
        dist.setMinPayout(address(stockA), 500e18);
        _fullCycle(1_000e18, 0);
        vm.prank(owner);
        dist.setAssetEnabled(address(stockA), false);
        vm.prank(h1);
        dist.claimAccrued(address(stockA)); // survives disable
        assertEq(stockA.balanceOf(h1), 100e18);
    }

    function test_RegisteredAsset_NeverSweepable() public {
        stockA.mint(address(dist), 1e18);
        vm.prank(owner);
        vm.expectRevert(bytes("registered asset"));
        dist.sweepForeign(address(stockA), owner);
    }

    function test_AbortCycle_PotRollsForward() public {
        stockA.mint(address(dist), 1_000e18);
        vm.startPrank(keeper);
        dist.startCycle();
        dist.abortCycle();
        assertEq(uint8(dist.phase()), 0);
        vm.stopPrank();
        _fullCycle(0, 0); // old 1000 becomes this cycle's pot
        assertEq(stockA.balanceOf(h3), 600e18);
    }

    // ---------------- fuzz: conservation under arbitrary pots/shares
    function testFuzz_NeverPaysMoreThanPot(uint96 pot, uint96 s1, uint96 s2, uint96 s3) public {
        vm.assume(uint256(s1) + s2 + s3 > 0);
        tracker.setShare(h1, s1); tracker.setShare(h2, s2); tracker.setShare(h3, s3);
        _fullCycle(pot, 0);
        uint256 paidOut = stockA.balanceOf(h1) + stockA.balanceOf(h2) + stockA.balanceOf(h3);
        assertLe(paidOut + stockA.balanceOf(address(dist)), uint256(pot) + 1); // conservation
        assertLe(paidOut, pot);
    }
}