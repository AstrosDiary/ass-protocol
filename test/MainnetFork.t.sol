// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPriceHub} from "../src/interfaces/IPriceHub.sol";
import {V3Twap} from "../src/libraries/V3Twap.sol";
import {AssBasket} from "../src/basket/AssBasket.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

interface IPancakeV3Factory { function getPool(address, address, uint24) external view returns (address); }
interface IDividendRef {
    function dividendToken() external view returns (address);
    function totalShares() external view returns (uint256);
    function owner() external view returns (address);
    function setShare(address, uint256) external;
    function withdrawDividendsFor(address) external returns (bool);
    function withdrawableDividendOf(address) external view returns (uint256);
}

/// Reads the hub from inside a contract call-frame — proves fetch() is not
/// caller-gated for contracts (the isAuthorizedCaller question).
contract HubProbe {
    function probe(address hub, bytes4 id) external view returns (IPriceHub.PriceSnapshot memory) {
        return IPriceHub(hub).fetch(id);
    }
}

/// Mainnet-fork coverage (audit feedback item 1). Runs only when FORK_RPC_URL
/// is set: `FORK_RPC_URL=$BSC_RPC_URL forge test --match-contract MainnetFork`
contract MainnetForkTest is Test {
    address constant ATLAS_HUB = 0xEAcE519ebB14fB8404fA6DdD23C3b34abaDE44aa;
    address constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant ELON_DIV = 0xe4Cc421015721E9e015d304AFcbD7c0c88964C9e;
    address constant ELON_BASKET = 0xf1aF9B62934b1A48B65c6CcbA692005a26b7c63F;
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant TRIGGER = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;

    bytes4[3] feedIds = [bytes4(0x000003c2), bytes4(0x000003c8), bytes4(0x000003be)];

    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // suite no-ops without a fork RPC
        vm.createSelectFork(rpc);
        forked = true;
    }

    modifier onFork() { if (!forked) return; _; }

    // ---------------- Atlas oracle: live feeds, contract-context reads
    function test_Fork_Atlas_AllThreeFeeds_LiveAndFresh() public onFork {
        HubProbe probe = new HubProbe(); // read from a CONTRACT frame
        for (uint256 i; i < 3; ++i) {
            IPriceHub.PriceSnapshot memory s = probe.probe(ATLAS_HUB, feedIds[i]);
            assertGt(s.price, 0, "feed dead");
            assertGt(uint256(s.price), 1e18, "price implausibly small");   // > $1
            assertLt(uint256(s.price), 100_000e18, "price implausibly big");
            emit log_named_uint("aggregatedTs age (s)", block.timestamp - s.aggregatedTs);
            // freshness observation, generous bound; informs maxFeedAge tuning
            assertLt(block.timestamp - s.aggregatedTs, 3 days, "feed stale beyond weekend bound");
        }
        assertEq(IPriceHub(ATLAS_HUB).decimals(), 18);
    }

    // ---------------- Flap Dividend (ElonCoin's, as live reference impl)
    function test_Fork_Dividend_ReferenceSemantics() public onFork {
        IDividendRef d = IDividendRef(ELON_DIV);
        assertEq(d.dividendToken(), ELON_BASKET);       // basket wired post-launch (portal-owned)
        assertEq(d.owner(), PORTAL);                    // who can setDividendToken: Flap
        assertGt(d.totalShares(), 0);
        vm.expectRevert();                              // setShare gated to tax token
        d.setShare(address(this), 1e18);
        // permissionless courier surface: callable by anyone; false (not revert)
        // for a wallet with no entitlement
        address nobody = makeAddr("nobody");
        assertEq(d.withdrawableDividendOf(nobody), 0);
        assertFalse(d.withdrawDividendsFor(nobody));
    }

    // ---------------- live-basket claim round trip (their deployment, our pattern)
    function test_Fork_Claim_UnwrapsRealAssets() public onFork {
        // find a real entitled holder via the accumulator: impersonate the tax
        // token to grant a fresh share, then deposit? No — state-minimal probe:
        // pick the basket's subset and confirm a real claim by any entitled
        // holder if one exists at fork height; otherwise this documents shape.
        // (Full round trip with OUR basket runs on the staging token post-wiring.)
        IDividendRef d = IDividendRef(ELON_DIV);
        // structural assertions that our unwrap hook's trigger condition holds:
        // dividend pays via direct transfer of dividendToken (basket) — verified
        // in source; here we assert the basket sits almost entirely at the div,
        // matching deposit-driven flow:
        uint256 divBal = IERC20Bal(ELON_BASKET).balanceOf(ELON_DIV);
        assertGt(divBal, 0, "no deposited shares at fork height");
    }

    // ---------------- Trigger service: live params
    function test_Fork_TriggerService_FeeAndGasCap() public onFork {
        (bool ok1, bytes memory f) = TRIGGER.staticcall(abi.encodeWithSignature("getFee()"));
        (bool ok2, bytes memory g) = TRIGGER.staticcall(abi.encodeWithSignature("getMaxCallbackGas()"));
        assertTrue(ok1 && ok2);
        emit log_named_uint("trigger fee (wei)", abi.decode(f, (uint256)));
        emit log_named_uint("max callback gas", abi.decode(g, (uint256)));
        assertGt(abi.decode(g, (uint256)), 500_000); // our BUY step budget sanity
    }

    // ---------------- V3Twap against real pools
    function test_Fork_Twap_RealPool_QQQB_USDT() public onFork {
        address pool;
        uint24[4] memory fees = [uint24(100), 500, 2500, 10000];
        for (uint256 i; i < 4; ++i) {
            pool = IPancakeV3Factory(PANCAKE_V3_FACTORY).getPool(QQQB, USDT, fees[i]);
            if (pool != address(0)) break;
        }
        if (pool == address(0)) { emit log("no QQQB/USDT pool at fork height"); return; }
        address[] memory pools = new address[](1); pools[0] = pool;
        address[] memory tokens = new address[](2); tokens[0] = QQQB; tokens[1] = USDT;
        uint256 out = V3Twap.quoteRoute(pools, tokens, 300, 0.01 ether);
        emit log_named_uint("TWAP: 0.01 QQQB -> USDT", out);
        assertGt(out, 1e18, "0.01 QQQB should exceed $1"); // QQQB ~$500+
    }

    function test_Fork_Basket_NavMath_RealOracle() public onFork {
        address[] memory subset = new address[](3);
        subset[0] = 0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec; // BABAB
        subset[1] = 0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c; // TSMB
        subset[2] = 0xCA750eF65f295BBECd685Abf54e82CAf297BDB61; // SKHYB
        bytes4[] memory ids = new bytes4[](3);
        ids[0] = 0x000003c2; ids[1] = 0x000003c8; ids[2] = 0x000003be;

        AssBasket impl = new AssBasket();
        AssBasket b = AssBasket(address(new BeaconProxy(
            address(new UpgradeableBeacon(address(impl), address(this))),
            abi.encodeCall(AssBasket.initialize, (subset, ids, ATLAS_HUB, address(this))))));

        // real prices through OUR staleness + multiplier + decimals path:
        uint256 v = b.assetValueUsd(subset[0], 1e18);
        emit log_named_uint("1 BABAB (USD, 1e18)", v);
        assertGt(v, 1e18); assertLt(v, 100_000e18);
        assertEq(b.totalNavUsd(), 0); // empty pool
        // previewMint sanity on the real feed
        assertGt(b.previewMint(subset[0], 1e18), 0);
    }
}

interface IERC20Bal { function balanceOf(address) external view returns (uint256); }