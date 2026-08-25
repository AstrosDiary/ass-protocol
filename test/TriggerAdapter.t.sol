// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {AssEngine} from "../src/engine/AssEngine.sol";
import {AssSwapExecutor} from "../src/adapters/AssSwapExecutor.sol";
import {AssTriggerAdapter} from "../src/adapters/AssTriggerAdapter.sol";
import {IFlapTriggerService, ITriggerReceiver} from "../src/flap/IFlapTriggerService.sol";
import {MockBStock} from "./mocks/MockBStock.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// Mock of FlapTriggerService faithful to the real contract's mechanics:
/// fee gate on request, PENDING -> EXECUTED set BEFORE the callback,
/// gas-capped callback, FAILED on revert (no revert bubbling), retry path.
contract MockTriggerService {
    enum Status { PENDING, EXECUTED, FAILED }
    struct Req { address requester; uint64 executeAfter; Status status; uint128 feePaid; }

    uint256 public fee = 0.002 ether;
    uint256 public maxCallbackGas = 2_000_000;
    uint256 public count;
    mapping(uint256 => Req) public reqs;

    error InsufficientGasFee(uint256 required, uint256 provided);

    function setFee(uint256 f) external { fee = f; }
    function getFee() external view returns (uint256) { return fee; }
    function getMaxCallbackGas() external view returns (uint256) { return maxCallbackGas; }

    function requestTrigger(uint64 executeAfter) external payable returns (uint256 id) {
        if (msg.value < fee) revert InsufficientGasFee(fee, msg.value);
        id = count++;
        reqs[id] = Req(msg.sender, executeAfter, Status.PENDING, uint128(msg.value));
    }

    /// test-driver: execute a request exactly like the real backend would
    function exec(uint256 id) external returns (bool success) {
        Req storage r = reqs[id];
        require(r.status == Status.PENDING, "not pending");
        r.status = Status.EXECUTED; // real service marks BEFORE the call
        (success,) = r.requester.call{gas: maxCallbackGas}(
            abi.encodeWithSelector(ITriggerReceiver.trigger.selector, id));
        if (!success) r.status = Status.FAILED;
    }

    function statusOf(uint256 id) external view returns (Status) { return reqs[id].status; }
}

contract MockWbnb {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function withdraw(uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok);
    }
    receive() external payable {}
}

contract MockVaultOps {
    MockBStock public immutable qqqb;
    address public engine;
    bool public revertRelease;
    constructor(MockBStock q) { qqqb = q; }
    function setEngine(address e) external { engine = e; }
    function setRevertRelease(bool r) external { revertRelease = r; }
    function pendingQuote() external view returns (uint256) { return qqqb.balanceOf(address(this)); }
    function release() external {
        require(!revertRelease, "release blocked");
        qqqb.transfer(engine, qqqb.balanceOf(address(this)));
    }
}

contract MockProcessable {
    uint256 public calls;
    bool public revertMode;
    function setRevert(bool r) external { revertMode = r; }
    function processReceived() external returns (uint256) {
        if (revertMode) revert("NothingToProcess");
        calls++;
        return 1e18;
    }
}

contract TriggerAdapterTest is Test {
    MockTriggerService svc;
    MockBStock qqqb;
    MockBStock babab;
    MockWbnb wbnbM;
    MockRouter router;
    MockVaultOps vaultM;
    AssEngine engine;
    AssSwapExecutor exec;
    AssTriggerAdapter adapter;
    address owner = makeAddr("owner");
    address distributor = makeAddr("distributor");

    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new BeaconProxy(address(new UpgradeableBeacon(impl, address(this))), init));
    }

    function setUp() public {
        vm.chainId(56);
        svc = new MockTriggerService();
        qqqb = new MockBStock();
        babab = new MockBStock();
        wbnbM = new MockWbnb();
        router = new MockRouter();
        vaultM = new MockVaultOps(qqqb);

        engine = AssEngine(_proxy(address(new AssEngine()), abi.encodeCall(AssEngine.initialize, (address(qqqb), owner))));
        exec = AssSwapExecutor(_proxy(address(new AssSwapExecutor()), abi.encodeCall(AssSwapExecutor.initialize, (address(qqqb), owner))));
        adapter = AssTriggerAdapter(payable(_proxy(address(new AssTriggerAdapter()),
            abi.encodeCall(AssTriggerAdapter.initialize, (address(svc), address(engine), address(wbnbM), owner)))));

        vaultM.setEngine(address(engine));

        vm.startPrank(owner);
        engine.setExecutor(address(exec));
        engine.setDistributor(distributor);
        engine.setKeeper(address(adapter), true);
        engine.addAsset(address(babab), 10_000, 100 ether); // 100% weight: clean numbers
        exec.setEngine(address(engine));
        exec.setRouter(address(router), true);
        adapter.setVault(address(vaultM));
        adapter.setSwapRouter(address(router));
        adapter.setParams(900, 300, 150, 0.005 ether, 0.01 ether, 0.01 ether);
        vm.stopPrank();

        vm.deal(address(adapter), 1 ether); // seeded gas tank
    }

    // route helper: MockRouter has no V3 pools, so we route "spot" via a mocked
    // TWAP — tests that need a successful quote mock twapQuoteExt directly.
    function _setRouteWithMockedTwap(uint256 quoteOut) internal {
        address[] memory pools = new address[](1);
        pools[0] = makeAddr("pool");
        address[] memory tokens = new address[](2);
        tokens[0] = address(qqqb); tokens[1] = address(babab);
        vm.prank(owner);
        adapter.setRoute(address(babab), pools, tokens, bytes("path"));
        vm.mockCall(address(adapter),
            abi.encodeWithSelector(adapter.twapQuoteExt.selector), abi.encode(quoteOut));
    }

    function _scheduleCycle() internal returns (uint256 id) {
        vm.prank(owner);
        id = adapter.scheduleCycle(0);
    }

    // ---------------- requirement 1+2: sender check (Critical per rubric)
    function test_Trigger_RejectsNonService() public {
        uint256 id = _scheduleCycle();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(AssTriggerAdapter.OnlyTriggerService.selector);
        adapter.trigger(id);
    }

    // ---------------- requirement 3: binding + replay protection
    function test_Trigger_ConsumesRequest_NoReplay() public {
        uint256 id = _scheduleCycle();
        assertTrue(svc.exec(id));
        (AssTriggerAdapter.Kind k,) = adapter.pending(id);
        assertEq(uint8(k), uint8(AssTriggerAdapter.Kind.NONE)); // consumed
        // replayed id: fail-soft Skipped, no state change, no revert
        vm.prank(address(svc));
        adapter.trigger(id);
    }

    function test_Trigger_UnknownId_FailsSoft() public {
        vm.prank(address(svc));
        adapter.trigger(999_999); // never requested: Skipped, not revert
    }

    // ---------------- requirement 4: delay-aware re-validation
    /// The service guarantees only "no earlier than" — state may have moved
    /// between request and execution. The BUY callback must re-read the LIVE
    /// budget and skip safely when the requested-time state no longer holds.
    function test_Buy_RevalidatesBudget_SkipsWhenGone() public {
        _setRouteWithMockedTwap(100e18);
        qqqb.mint(address(engine), 1 ether);
        uint256 cycleId = _scheduleCycle();
        assertTrue(svc.exec(cycleId));                 // processes -> budget, schedules BUY
        uint256 buyId = cycleId + 1;

        // budget is spent by the MANUAL keeper between the BUY request and its
        // execution (the fallback path acting first — a realistic race):
        vm.prank(owner);
        bool ok = engine.executeBuy(address(babab), address(router),
            abi.encodeCall(MockRouter.swap, (address(qqqb), address(babab), 0.9 ether)),
            0.9 ether, 1, block.timestamp + 60);
        assertTrue(ok);

        // callback executes late: re-validates live budget, skips, never reverts
        assertTrue(svc.exec(buyId));
        assertGt(engine.budget(address(babab)), 0);    // remainder untouched, carried forward
    }

    // ---------------- requirement 5+6: never-revert doctrine end-to-end
    function test_Cycle_FullPipeline_ReleaseProcessBuyReschedule() public {
        _setRouteWithMockedTwap(100e18);
        qqqb.mint(address(vaultM), 2 ether);           // tax sitting in vault
        router.setPair(address(qqqb), address(babab));
        router.setStrictDecode(true);

        uint256 cycleId = _scheduleCycle();
        assertTrue(svc.exec(cycleId));

        // released + processed (1% skim to adapter) + BUY scheduled + next CYCLE scheduled
        assertEq(qqqb.balanceOf(address(vaultM)), 0);                       // released
        assertGt(engine.budget(address(babab)), 0);                         // processed
        (AssTriggerAdapter.Kind k1, address a1) = adapter.pending(cycleId + 1);
        assertEq(uint8(k1), uint8(AssTriggerAdapter.Kind.BUY));
        assertEq(a1, address(babab));
        (AssTriggerAdapter.Kind k2,) = adapter.pending(cycleId + 2);
        assertEq(uint8(k2), uint8(AssTriggerAdapter.Kind.CYCLE));           // self-perpetuating

        // execute the BUY: stock lands in distributor via existing invariants
        assertTrue(svc.exec(cycleId + 1));
        assertGt(babab.balanceOf(distributor), 0);
    }

    function test_Cycle_VaultRevert_FailsSoft_RestStillRuns() public {
        _setRouteWithMockedTwap(100e18);
        qqqb.mint(address(vaultM), 1 ether);
        qqqb.mint(address(engine), 1 ether);           // engine has its own unprocessed too
        vaultM.setRevertRelease(true);

        uint256 id = _scheduleCycle();
        assertTrue(svc.exec(id));                      // callback SUCCEEDS despite release revert
        assertGt(engine.budget(address(babab)), 0);    // processing still happened
        (AssTriggerAdapter.Kind k,) = adapter.pending(id + 2);
        assertEq(uint8(k), uint8(AssTriggerAdapter.Kind.CYCLE)); // still re-armed
    }

    function test_Buy_TwapUnavailable_SkipsAndCarries() public {
        // real route, no mocked TWAP: observe() on a makeAddr pool reverts -> catch path
        address[] memory pools = new address[](1); pools[0] = makeAddr("pool");
        address[] memory tokens = new address[](2);
        tokens[0] = address(qqqb); tokens[1] = address(babab);
        vm.prank(owner);
        adapter.setRoute(address(babab), pools, tokens, bytes("path"));

        qqqb.mint(address(engine), 1 ether);
        uint256 cycleId = _scheduleCycle();
        assertTrue(svc.exec(cycleId));
        uint256 buyId = cycleId + 1;
        assertTrue(svc.exec(buyId));                   // no revert
        assertGt(engine.budget(address(babab)), 0);    // budget carried forward
    }

    /// Fail-soft split: the OWNER entry point must revert on an empty tank
    /// (a silently dead scheduler is worse than an error), while the INTERNAL
    /// self-rearm inside trigger() must never revert (callback safety) — it
    /// emits FundingLow and automation degrades to the manual keeper.
    function test_Cycle_NoBnb_OwnerRevertsLoud_CallbackLapsesSoft() public {
        // drain to exactly one fee: scheduling succeeds, but the tank is then empty
        vm.startPrank(owner);
        adapter.setPaused(true);                        // sweeps are decommission-gated
        adapter.sweepBnb(owner, address(adapter).balance - svc.getFee());
        adapter.setPaused(false);                       // resume live behavior
        uint256 id = adapter.scheduleCycle(0);
        vm.stopPrank();

        // callback runs on the empty tank: succeeds (never reverts), lapses via FundingLow
        qqqb.mint(address(engine), 1 ether);
        assertTrue(svc.exec(id));                       // fail-soft: callback OK
        (AssTriggerAdapter.Kind k,) = adapter.pending(id + 1);
        assertEq(uint8(k), uint8(AssTriggerAdapter.Kind.NONE)); // no re-arm possible

        // owner path on the same empty tank: loud revert
        vm.prank(owner);
        vm.expectRevert(bytes("insufficient BNB for fee"));
        adapter.scheduleCycle(0);
    }

    // ---------------- fee funding
    /// The engine's skim lands as QQQB on the adapter; when the BNB tank sits
    /// below feeFloor, the CYCLE callback converts it (TWAP-bounded swap ->
    /// WBNB -> unwrap) before doing anything else. "Fees paid directly from
    /// tax revenue," per the audit ask.
    function test_TopUpGas_SwapsSkimToBnb() public {
        // gas route + drained tank + skim balance present
        address[] memory pools = new address[](1); pools[0] = makeAddr("gpool");
        address[] memory tokens = new address[](2);
        tokens[0] = address(qqqb); tokens[1] = address(wbnbM);
        vm.prank(owner);
        adapter.setGasRoute(pools, tokens, bytes("gaspath"));
        vm.mockCall(address(adapter),
            abi.encodeWithSelector(adapter.gasTwapQuoteExt.selector), abi.encode(uint256(0.05 ether)));

        // hoisted BEFORE the prank: an external call in an argument (svc.getFee())
        // would consume vm.prank and sweepBnb would run unauthorized
        uint256 fee = svc.getFee();
        uint256 sweepAmt = address(adapter).balance - fee; // leave exactly one fee in the tank (below feeFloor)
        vm.startPrank(owner);
        adapter.setPaused(true);                        // sweeps are decommission-gated
        adapter.sweepBnb(owner, sweepAmt);
        adapter.setPaused(false);                       // resume live behavior
        vm.stopPrank();

        qqqb.mint(address(adapter), 1 ether);           // the skim
        vm.deal(address(wbnbM), 1 ether);               // wbnb can pay out withdrawals
        router.setPair(address(qqqb), address(wbnbM));  // fallback shim services the gas leg here
        router.setRate(1e18); // 1:1 QQQB->WBNB for this leg: keeps the unwrap within wbnbM's dealt backing

        uint256 id = _scheduleCycle();                  // consumes the last fee: tank now 0 (< feeFloor)
        assertTrue(svc.exec(id));                       // CYCLE: _topUpGas fires first
        assertGt(address(adapter).balance, 0);          // tank refilled from tax revenue
    }

    // ---------------- engine skim accounting
    function test_Skim_RoutesToAdapter_ExcludedFromCumulative() public {
        vm.prank(owner);
        engine.setGasFund(address(adapter), 100);       // 1%
        qqqb.mint(address(engine), 10 ether);
        vm.prank(owner);
        engine.processRevenue();
        assertEq(qqqb.balanceOf(address(adapter)), 0.1 ether);              // 1% skimmed
        assertEq(engine.budget(address(babab)), 9.9 ether);                 // 100% weight of post-skim
        assertEq(engine.cumulativeQuoteProcessed(), 9.9 ether);             // skim excluded
    }

    function test_Skim_CapEnforced() public {
        vm.prank(owner);
        vm.expectRevert(bytes("max 3%"));
        engine.setGasFund(address(adapter), 301);
    }

    // ---------------- initializer locks (audit item: proxy hygiene)
    function test_Initializers_Locked() public {
        AssTriggerAdapter rawImpl = new AssTriggerAdapter();
        vm.expectRevert();
        rawImpl.initialize(address(svc), address(engine), address(wbnbM), owner);
        vm.expectRevert();
        adapter.initialize(address(svc), address(engine), address(wbnbM), owner); // proxy: re-init blocked
    }

    // ---------------- guardian authority
    function test_Guardian_CanAdmin_StrangerCannot() public {
        address guardian = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        vm.prank(guardian);
        adapter.setPaused(true);                        // guardian: allowed
        assertTrue(adapter.paused());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AssTriggerAdapter.Unauthorized.selector);
        adapter.setPaused(false);
    }

    function test_Paused_StopsSelfRearm() public {
        vm.prank(owner);
        adapter.setPaused(true);
        qqqb.mint(address(engine), 1 ether);
        uint256 id = _scheduleCycle();
        assertTrue(svc.exec(id));
        (AssTriggerAdapter.Kind k,) = adapter.pending(id + 1);
        // with no route set, no BUY scheduled; paused => no CYCLE either
        assertEq(uint8(k), uint8(AssTriggerAdapter.Kind.NONE));
    }

    // ---------------- basket poke (post-migration cycle step)
    /// CYCLE advances the basket (mint+deposit of delivered stocks) via the
    /// engine's distributor pointer — permissionless on the basket, fail-soft
    /// here: NothingToProcess (empty cycle) and pre-wiring reverts are normal.
    function test_Cycle_PokesBasketProcessReceived() public {
        MockProcessable basket = new MockProcessable();
        vm.prank(owner);
        engine.setDistributor(address(basket));

        uint256 id = _scheduleCycle();
        assertTrue(svc.exec(id));
        assertEq(basket.calls(), 1);                    // poked exactly once per CYCLE
    }

    function test_Cycle_BasketPokeRevert_FailsSoft() public {
        MockProcessable basket = new MockProcessable();
        basket.setRevert(true);
        vm.prank(owner);
        engine.setDistributor(address(basket));

        qqqb.mint(address(engine), 1 ether);
        uint256 id = _scheduleCycle();
        assertTrue(svc.exec(id));                       // callback survives the revert
        assertGt(engine.budget(address(babab)), 0);     // rest of the cycle still ran
        (AssTriggerAdapter.Kind k,) = adapter.pending(id + 1);
        assertEq(uint8(k), uint8(AssTriggerAdapter.Kind.CYCLE)); // still re-armed (no route set -> no BUY)
    }
}