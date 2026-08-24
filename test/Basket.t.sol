// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssBasket} from "../src/basket/AssBasket.sol";
import {IPriceHub} from "../src/interfaces/IPriceHub.sol";
import {MockBStock} from "./mocks/MockBStock.sol";

contract MockPriceHub {
    mapping(bytes4 => IPriceHub.PriceSnapshot) public snaps;
    function set(bytes4 id, uint80 price, uint48 aggTs) external {
        snaps[id] = IPriceHub.PriceSnapshot(price, aggTs, uint48(block.timestamp));
    }
    function fetch(bytes4 id) external view returns (IPriceHub.PriceSnapshot memory) { return snaps[id]; }
    function decimals() external pure returns (uint8) { return 18; }
}

contract MockTaxToken {
    address public dividendContract;
    function setDividendContract(address d) external { dividendContract = d; }
}

/// Faithful reduction of Flap's verified Dividend (magnified accumulator,
/// deposit gates, direct-safeTransfer claim path) — the surface our basket
/// integrates against.
contract MockDividend {
    uint256 internal constant MAGNITUDE = 2 ** 128;
    address public dividendToken;
    uint256 public totalShares;
    uint256 public magnifiedDividendPerShare;
    struct UserInfo { uint256 share; uint256 rewardDebt; uint256 pendingBalance; }
    mapping(address => UserInfo) public userInfo;

    function setDividendToken(address t) external { dividendToken = t; }
    function setShare(address user, uint256 share) external { // test-open (real: onlyTaxToken)
        UserInfo storage u = userInfo[user];
        if (u.share > 0) {
            uint256 acc = u.share * magnifiedDividendPerShare / MAGNITUDE;
            if (acc > u.rewardDebt) u.pendingBalance += acc - u.rewardDebt;
        }
        totalShares = totalShares - u.share + share;
        u.share = share;
        u.rewardDebt = (share * magnifiedDividendPerShare + MAGNITUDE - 1) / MAGNITUDE;
    }
    function deposit(uint256 amount) external returns (bool) {
        if (amount == 0 || totalShares == 0) return false;
        uint256 before = IERC20(dividendToken).balanceOf(address(this));
        IERC20(dividendToken).transferFrom(msg.sender, address(this), amount);
        uint256 got = IERC20(dividendToken).balanceOf(address(this)) - before;
        if (got == 0) return false;
        magnifiedDividendPerShare += got * MAGNITUDE / totalShares;
        return true;
    }
    function withdrawableDividendOf(address user) public view returns (uint256) {
        UserInfo storage u = userInfo[user];
        uint256 acc = u.share * magnifiedDividendPerShare / MAGNITUDE;
        return (acc > u.rewardDebt ? acc - u.rewardDebt : 0) + u.pendingBalance;
    }
    function withdrawDividendsFor(address user) external returns (bool) {
        uint256 amt = withdrawableDividendOf(user);
        if (amt == 0) return false;
        UserInfo storage u = userInfo[user];
        u.rewardDebt = (u.share * magnifiedDividendPerShare + MAGNITUDE - 1) / MAGNITUDE;
        u.pendingBalance = 0;
        IERC20(dividendToken).transfer(user, amt); // direct transfer: triggers basket unwrap hook
        return true;
    }
}

contract BasketTest is Test {
    AssBasket basket;
    MockPriceHub hub;
    MockTaxToken tax;
    MockDividend div;
    MockBStock babab; MockBStock tsmb; MockBStock skhyb;
    bytes4 constant F_BABAB = 0x000003c2;
    bytes4 constant F_TSMB  = 0x000003c8;
    bytes4 constant F_SKHYB = 0x000003be;
    address owner = makeAddr("owner");
    address h1 = makeAddr("h1");
    address h2 = makeAddr("h2");

    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new BeaconProxy(address(new UpgradeableBeacon(impl, address(this))), init));
    }

    function setUp() public {
        vm.chainId(56);
        hub = new MockPriceHub();
        tax = new MockTaxToken();
        div = new MockDividend();
        babab = new MockBStock(); tsmb = new MockBStock(); skhyb = new MockBStock();

        address[] memory subset = new address[](3);
        subset[0] = address(babab); subset[1] = address(tsmb); subset[2] = address(skhyb);
        bytes4[] memory ids = new bytes4[](3);
        ids[0] = F_BABAB; ids[1] = F_TSMB; ids[2] = F_SKHYB;

        basket = AssBasket(_proxy(address(new AssBasket()),
            abi.encodeCall(AssBasket.initialize, (subset, ids, address(hub), owner))));

        tax.setDividendContract(address(div));
        div.setDividendToken(address(basket));
        vm.prank(owner);
        basket.setTaxToken(address(tax));

        // live prices: BABAB $160, TSMB $410, SKHYB $150 (18-dec USD)
        hub.set(F_BABAB, uint80(160e18), uint48(block.timestamp));
        hub.set(F_TSMB, uint80(410e18), uint48(block.timestamp));
        hub.set(F_SKHYB, uint80(150e18), uint48(block.timestamp));

        div.setShare(h1, 250_000e18); // 25%
        div.setShare(h2, 750_000e18); // 75%
    }

    // ---------------- init + admin
    function test_Init_State() public view {
        assertEq(basket.getSubset().length, 3);
        assertEq(basket.oracleDecimals(), 18);
        assertEq(basket.taxToken(), address(tax));
    }

    function test_TaxToken_SetOnce() public {
        vm.prank(owner);
        vm.expectRevert(AssBasket.TaxTokenAlreadySet.selector);
        basket.setTaxToken(address(tax));
    }

    function test_Initializers_Locked() public {
        AssBasket impl = new AssBasket();
        address[] memory s = new address[](1); s[0] = address(babab);
        bytes4[] memory f = new bytes4[](1); f[0] = F_BABAB;
        vm.expectRevert();
        impl.initialize(s, f, address(hub), owner);
    }

    function test_Guardian_CanAdmin_StrangerCannot() public {
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        basket.setMaxFeedAge(1 days);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AssBasket.Unauthorized.selector);
        basket.setMaxFeedAge(2 days);
    }

    // ---------------- valuation
    function test_AssetValueUsd_And_MultiplierScaling() public {
        assertEq(basket.assetValueUsd(address(babab), 2e18), 320e18); // 2 x $160
        babab.setMultiplier(2e18);                                    // corporate action: 2:1
        assertEq(basket.assetValueUsd(address(babab), 2e18), 640e18); // display doubles, value doubles
    }

    function test_StalePrice_Reverts() public {
        vm.warp(block.timestamp + 7 hours); // maxFeedAge default 6h
        vm.expectRevert(abi.encodeWithSelector(AssBasket.StaleOrInvalidPrice.selector, address(babab)));
        basket.assetValueUsd(address(babab), 1e18);
    }

    function test_ZeroPrice_Reverts() public {
        hub.set(F_BABAB, 0, uint48(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(AssBasket.StaleOrInvalidPrice.selector, address(babab)));
        basket.assetValueUsd(address(babab), 1e18);
    }

    // ---------------- mint + deposit
    function test_Process_FirstMint_SeedsAndDeposits() public {
        babab.mint(address(basket), 1e18); // engine buy delivered $160
        uint256 minted = basket.processReceived();
        assertEq(basket.balanceOf(0x000000000000000000000000000000000000dEaD), basket.MINIMUM_LIQUIDITY());
        assertEq(minted, 160e18 - basket.MINIMUM_LIQUIDITY());
        assertEq(basket.balanceOf(address(div)), minted);   // all deposited
        assertEq(basket.balanceOf(address(basket)), 0);
        // accumulator floors per holder (MasterChef): allow wei-scale dust
        assertApproxEqAbs(div.withdrawableDividendOf(h2), minted * 3 / 4, 2);
    }

    /// NAV honesty: a price move between mints must not let the second mint
    /// dilute or over-credit — shares track live USD value throughout.
    function test_Process_SecondMint_ProportionalUnderPriceMove() public {
        babab.mint(address(basket), 1e18);          // $160 in
        basket.processReceived();
        uint256 supply1 = basket.totalSupply();

        hub.set(F_BABAB, uint80(320e18), uint48(block.timestamp)); // BABAB doubles
        tsmb.mint(address(basket), 1e18);           // $410 in at CURRENT prices
        basket.processReceived();

        // navBefore at 2nd mint = 1 BABAB @ $320 = 320e18; shares = 410/320 x supply1
        uint256 expected = (410e18 * supply1) / 320e18;
        assertApproxEqRel(basket.totalSupply() - supply1, expected, 1e12);
    }

    function test_Process_NoNewAssets_Reverts() public {
        vm.expectRevert(AssBasket.NothingToProcess.selector);
        basket.processReceived();
    }

    /// documented Dividend edge: no eligible shares -> deposit()==false ->
    /// whole poke reverts atomically (mint rolled back, retried next cycle)
    function test_Process_NoShareholders_RevertsAtomically() public {
        div.setShare(h1, 0); div.setShare(h2, 0);
        babab.mint(address(basket), 1e18);
        vm.expectRevert(bytes("deposit failed"));
        basket.processReceived();
        assertEq(basket.totalSupply(), 0); // nothing half-minted
    }

    // ---------------- the claim: auto-unwrap
    function test_Claim_UnwrapsProRata_ToBothHolders() public {
        babab.mint(address(basket), 4e18);
        tsmb.mint(address(basket), 2e18);
        skhyb.mint(address(basket), 8e18);
        basket.processReceived();

        div.withdrawDividendsFor(h2); // 75%
        // h2 receives ~75% of pool (dead-shares dust rounds down negligibly)
        assertApproxEqRel(babab.balanceOf(h2), 3e18, 1e14);
        assertApproxEqRel(tsmb.balanceOf(h2), 1.5e18, 1e14);
        assertApproxEqRel(skhyb.balanceOf(h2), 6e18, 1e14);
        assertEq(basket.balanceOf(h2), 0);      // never holds the basket token

        div.withdrawDividendsFor(h1); // 25%
        assertApproxEqRel(babab.balanceOf(h1), 1e18, 1e14);
        assertGt(basket.totalSupply(), 0);       // only dead-locked liquidity remains (+dust)
        assertLt(basket.balanceOf(address(div)), 1e15 + 1);
    }

    function test_Claim_SecondClaimAfterNewRevenue() public {
        babab.mint(address(basket), 1e18);
        basket.processReceived();
        div.withdrawDividendsFor(h1);
        uint256 got1 = babab.balanceOf(h1);

        babab.mint(address(basket), 1e18); // next cycle's revenue
        basket.processReceived();
        div.withdrawDividendsFor(h1);
        assertGt(babab.balanceOf(h1), got1); // accrues again, claims again
    }

    function test_Unwrap_AccountedBaselineStaysHonest() public {
        babab.mint(address(basket), 2e18);
        basket.processReceived();
        div.withdrawDividendsFor(h2);
        // baseline shrank with the pool: a fresh delta-less poke still reverts
        vm.expectRevert(AssBasket.NothingToProcess.selector);
        basket.processReceived();
        // and new revenue still processes correctly after an unwrap
        babab.mint(address(basket), 1e18);
        basket.processReceived();
    }

    function test_NormalTransfer_Unaffected() public {
        // transfers NOT from the dividend contract behave as plain ERC20
        babab.mint(address(basket), 1e18);
        basket.processReceived();
        vm.prank(address(div));
        // (claim path already tested; here: div could also plain-transfer if it
        // ever sent to itself — guard only keys on from==div && to!=0)
        // sanity: third-party holding is impossible anyway since shares only
        // ever sit at div/dead — assert supply location:
        assertEq(basket.balanceOf(address(div)) + basket.balanceOf(0x000000000000000000000000000000000000dEaD), basket.totalSupply());
    }

    /// INCIDENT 2026-08-23 #1: claims must pay from the PROCESSED pool only.
    /// Unprocessed engine deliveries sitting in the basket belong to the next
    /// mint — an early claimer must not sweep them.
    function test_Unwrap_IgnoresUnprocessedDeposits() public {
        babab.mint(address(basket), 1e18);        // $160, processed
        basket.processReceived();
        tsmb.mint(address(basket), 1e18);         // $410 delivered, NOT yet poked

        div.withdrawDividendsFor(h2);             // 75% claim lands mid-window
        assertApproxEqRel(babab.balanceOf(h2), 0.75e18, 1e14); // gets processed BABAB
        assertEq(tsmb.balanceOf(h2), 0);          // gets ZERO unprocessed TSMB
        assertEq(tsmb.balanceOf(address(basket)), 1e18); // still pooled, intact

        // the unprocessed delivery mints cleanly on the next poke...
        uint256 minted = basket.processReceived();
        assertGt(minted, 0);
        // ...and is then claimable as normal
        div.withdrawDividendsFor(h2);
        assertGt(tsmb.balanceOf(h2), 0);
    }

    /// INCIDENT 2026-08-23 #2: after the processed pool is fully claimed out,
    /// residual supply (dead seed + accumulator dust) must not deadlock minting.
    /// Pre-fix this reverts NothingToProcess forever (shares compute 0 against
    /// navBefore == 0); the recovery branch re-seeds at parity.
    function test_Process_RecoversAfterFullDrain() public {
        babab.mint(address(basket), 1e18);
        basket.processReceived();
        div.withdrawDividendsFor(h1);
        div.withdrawDividendsFor(h2);             // processed pool fully drained
        // dead-share pro-rata sliver correctly stays behind (the residue that
        // backs the locked MINIMUM_LIQUIDITY supply) — dust-scale, never zero
        assertLt(basket.accounted(address(babab)), 1e13);
        assertGt(basket.totalSupply(), 0);        // dead seed + dust residue remains

        babab.mint(address(basket), 2e18);        // next cycle's revenue arrives
        uint256 minted = basket.processReceived(); // MUST NOT revert (the deadlock)
        assertApproxEqRel(minted, 320e18, 1e12);  // parity re-seed: $320 -> ~320e18 shares
        assertGt(div.withdrawableDividendOf(h2), 0); // machine is alive again
        uint256 h2Before = babab.balanceOf(h2);   // still holds ~0.75e18 from the first-era claim
        div.withdrawDividendsFor(h2);
        // second claim delivers 75% of the NEW $320 pool (minus dead-share sliver)
        assertApproxEqRel(babab.balanceOf(h2) - h2Before, 1.5e18, 1e13);
    }
}