// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssDistributor} from "../src/distributor/AssDistributor.sol";
import {MockFlapDividend} from "./mocks/MockFlapDividend.sol";
import {MockBStock} from "./mocks/MockBStock.sol";

contract DistributorHandler is Test {
    AssDistributor public dist;
    MockFlapDividend public tracker;
    MockBStock public stock;
    address[] public holders;

    constructor(AssDistributor d, MockFlapDividend t, MockBStock s) {
        dist = d; tracker = t; stock = s;
        for (uint160 i = 1; i <= 8; ++i) {
            holders.push(address(i * 0x1000));
            tracker.setShare(address(i * 0x1000), 100_000e18);
        }
    }

    function fundPot(uint96 amt) external { stock.mint(address(dist), bound(amt, 0, 1e24)); }

    function churnShare(uint8 hIdx, uint96 s) external {
        tracker.setShare(holders[hIdx % holders.length], bound(s, 0, 1e24));
    }

    function toggleRestrict(uint8 hIdx, bool on) external {
        stock.setRestricted(holders[hIdx % holders.length], on);
    }

    function runCycle(uint8 batchSize) external {
        if (uint8(dist.phase()) != 0) return;
        try dist.startCycle() {} catch { return; }
        address[] memory hs = holders; // already ascending by construction
        try dist.submitHolders(hs) {} catch { dist.abortCycle(); return; }
        try dist.finalizeSnapshot() {} catch { dist.abortCycle(); return; }
        uint256 b = bound(batchSize, 1, 8);
        while (uint8(dist.phase()) == 2) {
            try dist.pushPayouts(b) {} catch { dist.abortCycle(); return; }
        }
    }

    function claim(uint8 hIdx) external {
        address h = holders[hIdx % holders.length];
        vm.prank(h);
        try dist.claimAccrued(address(stock)) {} catch {}
    }

    function flush(uint8 hIdx) external {
        try dist.flushAccrued(address(stock), holders[hIdx % holders.length]) {} catch {}
    }

    function holdersLength() external view returns (uint256) { return holders.length; }
    function holderAt(uint256 i) external view returns (address) { return holders[i]; }
}

contract InvariantsTest is Test {
    AssDistributor dist;
    MockFlapDividend tracker;
    MockBStock stock;
    DistributorHandler handler;

    function setUp() public {
        dist = new AssDistributor(address(this));
        tracker = new MockFlapDividend();
        stock = new MockBStock();
        dist.setDividendTracker(address(tracker));
        dist.addAsset(address(stock));
        dist.setMinPayout(address(stock), 50e18);
        dist.setCoverageBps(0); // handler churns shares; coverage is unit-tested separately

        handler = new DistributorHandler(dist, tracker, stock);
        dist.setKeeper(address(handler), true);
        targetContract(address(handler));
    }

    /// THE ledger law: reserved counter == sum of individual accruals, always
    function invariant_ReservedEqualsSumOfAccrued() public view {
        uint256 sum;
        for (uint256 i; i < handler.holdersLength(); ++i) {
            sum += dist.accrued(address(stock), handler.holderAt(i));
        }
        assertEq(dist.reservedForAccrued(address(stock)), sum);
    }

    /// solvency: the contract always holds at least what it owes
    function invariant_BalanceCoversReserved() public view {
        assertGe(stock.balanceOf(address(dist)), dist.reservedForAccrued(address(stock)));
    }

    /// phase machine never wedges outside its three states
    function invariant_PhaseSane() public view {
        assertLe(uint8(dist.phase()), 2);
    }
}