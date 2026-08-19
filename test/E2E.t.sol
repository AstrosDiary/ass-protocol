// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {AssVault} from "../src/vault/AssVault.sol";
import {AssVaultFactory} from "../src/vault/AssVaultFactory.sol";
import {AssEngine} from "../src/engine/AssEngine.sol";
import {AssSwapExecutor} from "../src/adapters/AssSwapExecutor.sol";
import {AssDistributor} from "../src/distributor/AssDistributor.sol";
import {AssViews} from "../src/views/AssViews.sol";
import {MockBStock} from "./mocks/MockBStock.sol";
import {MockFlapDividend} from "./mocks/MockFlapDividend.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract E2ETest is Test {
    address constant PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7; // vault's hardcoded quote

    AssVault vault;
    AssEngine engine;
    AssSwapExecutor exec;
    AssDistributor dist;
    AssViews views;
    MockBStock qqqb; // mock etched AT the real QQQB address
    MockFlapDividend tracker;
    MockRouter pancake;
    MockRouter altRouter;

    MockBStock babab; MockBStock tsmb; MockBStock skhyb; MockBStock stock4;
    address[] stocks;

    address deployer = makeAddr("deployer"); // owner AND keeper, per your call
    address taxProcessor = makeAddr("taxProcessor");
    address h1 = address(0x1000); address h2 = address(0x2000); address h3 = address(0x3000);

    function setUp() public {
        vm.chainId(56);

        // quote mock lives at the REAL QQQB address so AssVault's constant resolves
        deployCodeTo("test/mocks/MockBStock.sol:MockBStock", QQQB);
        qqqb = MockBStock(QQQB);

        // --- production deploy sequence, exactly as DeployCore scripts it ---
        vm.startPrank(deployer);
        AssVault impl = new AssVault();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), deployer); // -> Guardian pre-audit
        AssVaultFactory factory = new AssVaultFactory(address(beacon));
        vm.stopPrank();

        address predictedToken = makeAddr("assToken");
        vm.prank(PORTAL); // portal creates the vault during token launch
        vault = AssVault(payable(factory.newVault(predictedToken, QQQB, deployer, "")));

        tracker = new MockFlapDividend();
        pancake = new MockRouter();
        altRouter = new MockRouter();
        babab = new MockBStock(); tsmb = new MockBStock(); skhyb = new MockBStock(); stock4 = new MockBStock();
        stocks = [address(babab), address(tsmb), address(skhyb), address(stock4)];

        vm.startPrank(deployer);
        engine = new AssEngine(QQQB, deployer);
        exec = new AssSwapExecutor(QQQB, deployer);
        dist = new AssDistributor(deployer);

        vault.setEngine(address(engine));
        engine.setExecutor(address(exec));
        engine.setDistributor(address(dist));
        engine.setKeeper(deployer, true);
        exec.setEngine(address(engine));
        exec.setRouter(address(pancake), true);
        exec.setRouter(address(altRouter), true);
        dist.setKeeper(deployer, true);
        dist.setDividendTracker(address(tracker));
        for (uint256 i; i < 4; ++i) {
            engine.addAsset(stocks[i], 2500, 100 ether); // 25/25/25/25
            dist.addAsset(stocks[i]);
        }
        vm.stopPrank();

        views = new AssViews(address(vault), address(engine), address(dist), address(tracker));

        tracker.setShare(h1, 100_000e18);
        tracker.setShare(h2, 300_000e18);
        tracker.setShare(h3, 600_000e18);
    }

    function _cd(MockRouter, address tokenOut, uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encodeCall(MockRouter.swap, (QQQB, tokenOut, amountIn));
    }

    /// One full protocol heartbeat: trades happened -> everyone got stocks.
    function test_E2E_TaxToHolderStocks_FullPipeline() public {
        // 1. Flap dispatches tax revenue to the vault — a plain QQQB transfer
        qqqb.mint(address(vault), 20 ether);

        // 2. keeper heartbeat: release -> split -> four buys (asset-4 via alt router)
        vm.startPrank(deployer);
        vault.release();
        engine.processRevenue();
        for (uint256 i; i < 4; ++i) {
            MockRouter r = stocks[i] == address(stock4) ? altRouter : pancake;
            assertTrue(engine.executeBuy(
                stocks[i], address(r), _cd(r, stocks[i], 5 ether),
                5 ether, 450e18, block.timestamp + 60
            ));
        }
        // 3. distribution cycle
        dist.startCycle();
        address[] memory hs = new address[](3);
        hs[0] = h1; hs[1] = h2; hs[2] = h3;
        dist.submitHolders(hs);
        dist.finalizeSnapshot();
        dist.pushPayouts(100);
        vm.stopPrank();

        // 4. every holder holds all four bStocks, pro-rata, raw units
        for (uint256 i; i < 4; ++i) {
            assertEq(MockBStock(stocks[i]).balanceOf(h1), 50e18);   // 10% of 500
            assertEq(MockBStock(stocks[i]).balanceOf(h2), 150e18);  // 30%
            assertEq(MockBStock(stocks[i]).balanceOf(h3), 300e18);  // 60%
        }
        // 5. books balance end-to-end
        assertEq(vault.totalReceived(), 20 ether);
        assertEq(vault.totalReleased(), 20 ether);
        assertEq(engine.cumulativeQuoteProcessed(), 20 ether); // 4 x 2500 bps = full allocation
        assertEq(uint8(dist.phase()), 0);
    }

    /// Spec headline scenario: asset-4 has no route this cycle. Three assets pay,
    /// asset-4's budget carries; next heartbeat it catches up. Nothing reverts.
    function test_E2E_OneAssetDown_CarryForward_ThenCatchUp() public {
        qqqb.mint(address(vault), 20 ether);

        altRouter.setMode(MockRouter.Mode.Revert); // alt route dead this cycle

        vm.startPrank(deployer);
        vault.release();
        engine.processRevenue();
        for (uint256 i; i < 4; ++i) {
            MockRouter r = stocks[i] == address(stock4) ? altRouter : pancake;
            engine.executeBuy(stocks[i], address(r), _cd(r, stocks[i], 5 ether),
                5 ether, 450e18, block.timestamp + 60); // asset-4 returns false, others true
        }
        dist.startCycle();
        address[] memory hs = new address[](3);
        hs[0] = h1; hs[1] = h2; hs[2] = h3;
        dist.submitHolders(hs);
        dist.finalizeSnapshot();
        dist.pushPayouts(100);
        vm.stopPrank();

        assertEq(babab.balanceOf(h3), 300e18);                // three assets paid
        assertEq(stock4.balanceOf(h3), 0);                    // asset-4 skipped cleanly
        assertEq(engine.budget(address(stock4)), 5 ether);    // budget carried

        // next heartbeat: route back, asset-4 catches up alone
        altRouter.setMode(MockRouter.Mode.Honest);
        vm.startPrank(deployer);
        assertTrue(engine.executeBuy(address(stock4), address(altRouter),
            _cd(altRouter, address(stock4), 5 ether), 5 ether, 450e18, block.timestamp + 60));
        dist.startCycle();
        dist.submitHolders(hs);
        dist.finalizeSnapshot();
        dist.pushPayouts(100);
        vm.stopPrank();
        assertEq(stock4.balanceOf(h3), 300e18);               // made whole
    }

    /// Spec release gate: thousands of holders through paginated payouts.
    function test_E2E_ThousandsOfHolders_PaginatedCycle() public {
        uint256 N = 3000;
        address[] memory hs = new address[](N);
        for (uint256 i; i < N; ++i) {
            address h = address(uint160(0x100000 + i)); // ascending by construction
            hs[i] = h;
            tracker.setShare(h, 10_000e18);
        }
        babab.mint(address(dist), 3_000e18);

        vm.startPrank(deployer);
        dist.startCycle();
        for (uint256 off; off < N; off += 500) { // batched submission
            address[] memory chunk = new address[](500);
            for (uint256 j; j < 500; ++j) chunk[j] = hs[off + j];
            dist.submitHolders(chunk);
        }
        dist.finalizeSnapshot();
        uint256 pushes;
        while (uint8(dist.phase()) == 2) { dist.pushPayouts(150); pushes++; } // Loxley batch size
        vm.stopPrank();

        assertEq(pushes, 20);                       // 3000 / 150
        assertEq(babab.balanceOf(hs[0]), 1e18);     // exact equal split
        assertEq(babab.balanceOf(hs[N - 1]), 1e18);
        assertEq(dist.cumulativeDistributed(address(babab)), 3_000e18);
    }

    /// Views coverage: the lens reports what actually happened.
    function test_E2E_ViewsReflectRealState() public {
        test_E2E_TaxToHolderStocks_FullPipeline();

        AssViews.ProtocolStats memory s = views.protocolStats();
        assertEq(s.vaultTotalReceivedQuote, 20 ether);
        assertEq(s.vaultTotalReleasedQuote, 20 ether);
        assertEq(s.cumulativeQuoteProcessed, 20 ether);
        assertEq(s.trackerTotalShares, 1_000_000e18);
        assertEq(s.distributorPhase, 0);
        assertEq(s.assetCount, 4);

        AssViews.AssetCard[] memory cards = views.assetCards();
        assertEq(cards.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(cards[i].weightBps, 2500);
            assertEq(cards[i].cumulativeSpentQuote, 5 ether);
            assertEq(cards[i].cumulativeBoughtRaw, 500e18);
            assertEq(cards[i].cumulativeDistributedRaw, 500e18);
        }

        AssViews.HolderCard memory hc = views.holderCard(h2);
        assertEq(hc.trackerShare, 300_000e18);
        assertFalse(hc.excluded);
        assertEq(hc.accruedRaw.length, 4);
    }

    /// Multiplier shift mid-pipeline: raw flow identical, display doubles.
    /// (Note this now also implicitly covers the QUOTE being a bStock with its
    /// own multiplier — all engine/vault accounting is raw-units throughout.)
    function test_E2E_CorporateActionMidPipeline_RawUnaffected() public {
        babab.setMultiplier(2e18);
        test_E2E_TaxToHolderStocks_FullPipeline();      // passes untouched
        assertEq(babab.scaledBalanceOf(h3), 600e18);    // display = 300 raw x2
    }
}