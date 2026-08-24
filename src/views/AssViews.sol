// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AssEngine} from "../engine/AssEngine.sol";
import {AssBasket} from "../basket/AssBasket.sol";

interface IAssVaultViews {
    function totalReceived() external view returns (uint256);
    function totalReleased() external view returns (uint256);
    function pendingQuote() external view returns (uint256);
}

interface ITaxTokenViews {
    function dividendContract() external view returns (address);
}

interface IDividendViews {
    function totalShares() external view returns (uint256);
    function minimumShareBalance() external view returns (uint256);
    function userInfo(address) external view returns (uint256 share, uint256 rewardDebt, uint256 pendingBalance);
    function excludedFromDividends(address) external view returns (bool);
    function withdrawableDividendOf(address) external view returns (uint256);
    function totalDividendsDistributed() external view returns (uint256);
}

/// @title AssViews v3 — read-only aggregation for the $ASS web app (basket era)
/// @notice Pure lens: no state, no admin, no funds. Batches protocol + holder
/// state into single eth_calls so the frontend never loops RPC requests.
/// Post-migration surface: AssDistributor and cycle machinery are GONE —
/// distribution runs through the IB-ASS basket + Flap's Dividend contract
/// (shares AND payout accounting live in one Flap-native contract, derived
/// live via basket.taxToken().dividendContract(), so this lens is deployable
/// before launch wiring and simply reports zeros until linked).
/// All amounts RAW on-chain units (quote = QQQB; shares 1e18-per-USD at mint) —
/// BEP-677 multiplier normalization is the display layer's job, never here.
contract AssViews {
    string public constant VERSION = "3.0.0";

    IAssVaultViews public immutable vault;
    AssEngine public immutable engine;
    AssBasket public immutable basket;

    constructor(address vault_, address engine_, address basket_) {
        vault = IAssVaultViews(vault_);
        engine = AssEngine(engine_);
        basket = AssBasket(basket_);
    }

    // ------------------------------------------------------------ derivation
    /// @notice live Dividend contract (0x0 until basket.setTaxToken + launch)
    function dividendContract() public view returns (address) {
        address t = basket.taxToken();
        if (t == address(0)) return address(0);
        return ITaxTokenViews(t).dividendContract();
    }

    // ------------------------------------------------------------ structs
    struct AssetCard {
        address asset;
        bool enabledEngine;          // receiving new budget
        uint16 weightBps;
        uint128 maxSpendPerBuy;
        uint256 budgetQuote;         // carry-forward visible per asset (QQQB)
        uint256 cumulativeSpentQuote;
        uint256 cumulativeBoughtRaw;
        uint256 pooledRaw;           // backing the basket's outstanding shares
        uint256 unprocessedRaw;      // delivered by buys, awaiting next mint poke
        uint256 priceUsd1e18;        // live Atlas price (0 if stale/unset — UI shows dash)
    }

    struct ProtocolStats {
        uint256 vaultTotalReceivedQuote;
        uint256 vaultTotalReleasedQuote;
        uint256 vaultPendingQuote;
        uint256 engineUnallocatedQuote;
        uint256 cumulativeQuoteProcessed;
        uint256 basketNavUsd1e18;        // live oracle NAV of the pool (0 if any feed stale)
        uint256 basketTotalSupply;       // shares outstanding (incl. dead-locked seed)
        uint256 sharesAtDividend;        // deposited, backing holder entitlements
        uint256 divTotalShares;          // Flap Dividend share accounting
        uint256 divMinimumShare;
        uint256 totalDividendsDistributed; // cumulative shares ever deposited
        uint256 assetCount;
        address dividendContract_;       // 0x0 = pre-wiring
    }

    struct HolderCard {
        uint256 share;               // live eligible share (0 = below min / excluded)
        bool excluded;
        uint256 claimableShares;     // withdrawableDividendOf — 1e18-per-USD units
        address[] assets;            // claim preview: order-matched arrays
        uint256[] claimAmountsRaw;   // what the unwrap would deliver right now
    }

    // ------------------------------------------------------------ views
    function protocolStats() external view returns (ProtocolStats memory s) {
        s.vaultTotalReceivedQuote = vault.totalReceived();
        s.vaultTotalReleasedQuote = vault.totalReleased();
        s.vaultPendingQuote = vault.pendingQuote();
        s.engineUnallocatedQuote = engine.unallocatedQuote();
        s.cumulativeQuoteProcessed = engine.cumulativeQuoteProcessed();
        s.basketTotalSupply = basket.totalSupply();
        s.assetCount = engine.assetsCount();
        s.basketNavUsd1e18 = _tryNav();
        address div = dividendContract();
        s.dividendContract_ = div;
        if (div != address(0)) {
            s.sharesAtDividend = basket.balanceOf(div);
            s.divTotalShares = IDividendViews(div).totalShares();
            s.divMinimumShare = IDividendViews(div).minimumShareBalance();
            s.totalDividendsDistributed = IDividendViews(div).totalDividendsDistributed();
        }
    }

    /// @dev one card per engine-registered asset; disabled assets stay visible
    /// forever (zero-weight-over-removal — legacy data never vanishes).
    function assetCards() public view returns (AssetCard[] memory cards) {
        uint256 n = engine.assetsCount();
        cards = new AssetCard[](n);
        for (uint256 i; i < n; ++i) {
            address a = engine.allAssets(i);
            (, bool enE, uint16 w, uint128 cap) = engine.assets(a);
            uint256 bal = IERC20(a).balanceOf(address(basket));
            uint256 acc = basket.accounted(a);
            cards[i] = AssetCard({
                asset: a,
                enabledEngine: enE,
                weightBps: w,
                maxSpendPerBuy: cap,
                budgetQuote: engine.budget(a),
                cumulativeSpentQuote: engine.cumulativeSpent(a),
                cumulativeBoughtRaw: engine.cumulativeBought(a),
                pooledRaw: bal,
                unprocessedRaw: bal > acc ? bal - acc : 0,
                priceUsd1e18: _tryPrice(a)
            });
        }
    }

    function holderCard(address h) external view returns (HolderCard memory c) {
        address div = dividendContract();
        uint256 n = engine.assetsCount();
        c.assets = new address[](n);
        c.claimAmountsRaw = new uint256[](n);
        for (uint256 i; i < n; ++i) c.assets[i] = engine.allAssets(i);
        if (div == address(0)) return c;

        (uint256 share,,) = IDividendViews(div).userInfo(h);
        c.share = share;
        c.excluded = IDividendViews(div).excludedFromDividends(h);
        c.claimableShares = IDividendViews(div).withdrawableDividendOf(h);

        // claim preview: mirrors _unwrapFrom — pooled[i] * shares / totalSupply
        uint256 supply = basket.totalSupply();
        if (c.claimableShares != 0 && supply != 0) {
            for (uint256 i; i < n; ++i) {
                c.claimAmountsRaw[i] =
                    Math.mulDiv(IERC20(c.assets[i]).balanceOf(address(basket)), c.claimableShares, supply);
            }
        }
    }

    // ------------------------------------------------------------ internal
    /// @dev oracle reads revert on staleness by design; a lens must not.
    function _tryNav() internal view returns (uint256) {
        try basket.totalNavUsd() returns (uint256 nav) { return nav; } catch { return 0; }
    }

    function _tryPrice(address a) internal view returns (uint256) {
        try basket.assetValueUsd(a, 1e18) returns (uint256 v) { return v; } catch { return 0; }
    }
}