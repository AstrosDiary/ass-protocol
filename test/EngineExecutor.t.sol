// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssEngine} from "../src/engine/AssEngine.sol";
import {AssSwapExecutor} from "../src/adapters/AssSwapExecutor.sol";
import {MockBStock} from "./mocks/MockBStock.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract EngineExecutorTest is Test {
    AssEngine engine;
    AssSwapExecutor exec;
    MockBStock qqqb; // quote token (constructor-injected — no etching needed)
    MockBStock babab;
    MockBStock stock4;
    MockRouter router;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address distributor = makeAddr("distributor");

    function setUp() public {
        qqqb = new MockBStock();
        babab = new MockBStock();
        stock4 = new MockBStock();
        router = new MockRouter();

        engine = new AssEngine(address(qqqb), owner);
        exec = new AssSwapExecutor(address(qqqb), owner);

        vm.startPrank(owner);
        engine.setKeeper(keeper, true);
        engine.setExecutor(address(exec));
        engine.setDistributor(distributor);
        engine.addAsset(address(babab), 2500, 10 ether);
        engine.addAsset(address(stock4), 2500, 10 ether);
        exec.setEngine(address(engine));
        exec.setRouter(address(router), true);
        vm.stopPrank();
    }

    function _cd(address tokenOut, uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeCall(MockRouter.swap, (address(qqqb), tokenOut, amountIn));
    }

    function test_ProcessRevenue_SplitsByWeight_RemainderUnallocated() public {
        qqqb.mint(address(engine), 10 ether);
        vm.prank(keeper);
        engine.processRevenue();
        assertEq(engine.budget(address(babab)), 2.5 ether);
        assertEq(engine.budget(address(stock4)), 2.5 ether);
        assertEq(engine.unallocatedQuote(), 5 ether); // 50% unweighted rolls forward
        // cumulative counts ALLOCATED only (double-count-proof): 5, not 10
        assertEq(engine.cumulativeQuoteProcessed(), 5 ether);
    }

    function test_ProcessRevenue_UnallocatedRollsIn_NoDoubleCount() public {
        // new coverage for the QQQB balance-sharing semantics: reprocessing
        // must pick up ONLY the unearmarked remainder, never re-count budgets
        qqqb.mint(address(engine), 10 ether);
        vm.prank(keeper);
        engine.processRevenue();                      // allocates 5, leaves 5 unallocated
        vm.prank(keeper);
        engine.processRevenue();                      // rolls the remaining 5: allocates 2.5
        assertEq(engine.budget(address(babab)), 3.75 ether);
        assertEq(engine.budget(address(stock4)), 3.75 ether);
        assertEq(engine.cumulativeQuoteProcessed(), 7.5 ether); // 5 + 2.5, budgets never re-counted
    }

    function test_ExecuteBuy_Happy_StockLandsInDistributor() public {
        qqqb.mint(address(engine), 10 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        bool ok = engine.executeBuy(
            address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 90e18, block.timestamp + 60
        );
        vm.stopPrank();
        assertTrue(ok);
        assertEq(babab.balanceOf(distributor), 100e18);   // recipient fixed
        assertEq(engine.budget(address(babab)), 1.5 ether);
        assertEq(engine.cumulativeBought(address(babab)), 100e18);
    }

    // ---------------- failure isolation: budget survives every betrayal
    function test_RouterReverts_BudgetIntact_NoRevert() public {
        router.setMode(MockRouter.Mode.Revert);
        qqqb.mint(address(engine), 10 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        bool ok = engine.executeBuy(
            address(stock4), address(router), _cd(address(stock4), 1 ether),
            1 ether, 90e18, block.timestamp + 60
        );
        vm.stopPrank();
        assertFalse(ok);                                     // isolated, not reverted
        assertEq(engine.budget(address(stock4)), 2.5 ether); // carry-forward automatic
        assertEq(qqqb.balanceOf(address(engine)), 10 ether); // funds fully unwound
    }

    function test_UnderDelivery_SlippageCaughtByMeasuredDelta() public {
        router.setMode(MockRouter.Mode.UnderDeliver);
        qqqb.mint(address(engine), 10 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        bool ok = engine.executeBuy(
            address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 90e18, block.timestamp + 60
        );
        vm.stopPrank();
        assertFalse(ok);
        assertEq(babab.balanceOf(distributor), 0);
        assertEq(engine.budget(address(babab)), 2.5 ether);
    }

    function test_WrongRecipient_DeltaZero_Reverts() public {
        router.setMode(MockRouter.Mode.WrongRecipient); // pays a thief, not executor
        qqqb.mint(address(engine), 10 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        bool ok = engine.executeBuy(
            address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 90e18, block.timestamp + 60
        );
        vm.stopPrank();
        assertFalse(ok); // measured-delta invariant: theft = delta 0 = slippage revert
    }

    function test_PartialSpend_LeftoverReturnsToEngine_BudgetOnlyDebitedSpent() public {
        router.setMode(MockRouter.Mode.PartialSpend);
        qqqb.mint(address(engine), 10 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        bool ok = engine.executeBuy(
            address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 40e18, block.timestamp + 60
        );
        vm.stopPrank();
        assertTrue(ok);
        assertEq(engine.budget(address(babab)), 2 ether);  // only 0.5 spent
        assertEq(qqqb.balanceOf(address(exec)), 0);        // nothing strands in executor
    }

    // ---------------- guardrails
    function test_RevertWhen_OverBudget() public {
        qqqb.mint(address(engine), 1 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        vm.expectRevert(AssEngine.OverBudget.selector);
        engine.executeBuy(address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 1, block.timestamp + 60);
        vm.stopPrank();
    }

    function test_RevertWhen_OverMaxSpend() public {
        vm.prank(owner);
        engine.configureAsset(address(babab), true, 2500, 0.1 ether);
        qqqb.mint(address(engine), 10 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        vm.expectRevert(AssEngine.OverMaxSpend.selector);
        engine.executeBuy(address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 1, block.timestamp + 60);
        vm.stopPrank();
    }

    function test_RevertWhen_AssetIsQuote() public {
        vm.prank(owner);
        vm.expectRevert(AssEngine.AssetIsQuote.selector);
        engine.addAsset(address(qqqb), 1000, 1 ether); // basket asset can never be the quote
    }

    function test_ExecutorRejects_UnallowedRouter_ZeroMinOut_Deadline_Stranger() public {
        qqqb.mint(address(engine), 10 ether);
        vm.prank(keeper); engine.processRevenue();

        MockRouter rogue = new MockRouter();
        vm.prank(keeper);
        assertFalse(engine.executeBuy(address(babab), address(rogue), _cd(address(babab), 1 ether),
            1 ether, 1, block.timestamp + 60)); // RouterNotAllowed -> isolated false

        vm.prank(keeper);
        assertFalse(engine.executeBuy(address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 0, block.timestamp + 60)); // ZeroMinOut

        vm.prank(keeper);
        assertFalse(engine.executeBuy(address(babab), address(router), _cd(address(babab), 1 ether),
            1 ether, 1, block.timestamp - 1)); // DeadlinePassed

        vm.expectRevert(AssSwapExecutor.OnlyEngine.selector);
        exec.execute(address(router), "", 1, address(babab), 1, distributor, block.timestamp + 60);
    }

    function test_ReassignBudget_KeeperOnly_BasketInternal() public {
        qqqb.mint(address(engine), 10 ether);
        vm.startPrank(keeper);
        engine.processRevenue();
        engine.reassignBudget(address(stock4), address(babab), 1 ether); // asset-4 stuck -> BABAB
        vm.stopPrank();
        assertEq(engine.budget(address(babab)), 3.5 ether);
        assertEq(engine.budget(address(stock4)), 1.5 ether);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(AssEngine.NotKeeper.selector);
        engine.reassignBudget(address(stock4), address(babab), 1);
    }

    function testFuzz_WeightSplit_NeverExceedsBalance(uint96 amount, uint16 w1, uint16 w2) public {
        vm.assume(uint256(amount) >= engine.minProcessAmount());
        w1 = uint16(bound(w1, 0, 5000)); w2 = uint16(bound(w2, 0, 5000));
        vm.startPrank(owner);
        engine.configureAsset(address(babab), true, w1, type(uint128).max);
        engine.configureAsset(address(stock4), true, w2, type(uint128).max);
        vm.stopPrank();
        qqqb.mint(address(engine), amount);
        vm.prank(keeper);
        engine.processRevenue();
        assertLe(engine.budget(address(babab)) + engine.budget(address(stock4)),
                 qqqb.balanceOf(address(engine)));
    }
}