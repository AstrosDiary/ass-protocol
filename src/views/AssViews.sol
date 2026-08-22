// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssEngine} from "../engine/AssEngine.sol";
import {AssDistributor} from "../distributor/AssDistributor.sol";
import {IFlapDividend} from "../interfaces/IFlapDividend.sol";

interface IAssVaultViews {
    function totalReceived() external view returns (uint256);
    function totalReleased() external view returns (uint256);
    function pendingQuote() external view returns (uint256);
}

/// @title AssViews v2 — read-only aggregation for the $ASS web app and keeper
/// @notice Pure lens: no state, no admin, no funds. Batches protocol + holder
/// state into single eth_calls so the frontend never loops RPC requests.
/// All amounts RAW on-chain units (quote = QQQB) — BEP-677 multiplier
/// normalization is the display layer's job, never done here.
contract AssViews {
    string public constant VERSION = "2.0.0";

    IAssVaultViews public immutable vault;
    AssEngine public immutable engine;
    AssDistributor public immutable distributor;
    IFlapDividend public immutable tracker;

    constructor(address vault_, address engine_, address distributor_, address tracker_) {
        vault = IAssVaultViews(vault_);
        engine = AssEngine(engine_);
        distributor = AssDistributor(distributor_);
        tracker = IFlapDividend(tracker_);
    }

    struct AssetCard {
        address asset;
        bool enabledEngine;      // receiving new budget
        bool enabledDistributor; // included in new payout cycles
        uint16 weightBps;
        uint128 maxSpendPerBuy;
        uint256 budgetQuote;         // carry-forward visible per asset (QQQB)
        uint256 cumulativeSpentQuote;
        uint256 cumulativeBoughtRaw;
        uint256 cumulativeDistributedRaw;
        uint256 distributorBalanceRaw;   // bought, awaiting next cycle pot
        uint256 reservedForAccruedRaw;   // owed dust, spoken for
        uint256 minPayoutRaw;
    }

    struct ProtocolStats {
        uint256 vaultTotalReceivedQuote;
        uint256 vaultTotalReleasedQuote;
        uint256 vaultPendingQuote;
        uint256 engineUnallocatedQuote;   // revenue awaiting processRevenue + rounding dust
        uint256 cumulativeQuoteProcessed;
        uint256 trackerTotalShares;
        uint256 trackerMinimumShare;
        uint8   distributorPhase;   // 0 Idle, 1 Snapshot, 2 Payout
        uint64  currentCycleId;
        uint256 assetCount;
    }

    struct HolderCard {
        uint256 trackerShare;       // live eligible share (0 = excluded/below min)
        bool    excluded;
        uint256[] accruedRaw;       // pending dust per asset, order matches assetCards()
    }

    function protocolStats() external view returns (ProtocolStats memory s) {
        s.vaultTotalReceivedQuote = vault.totalReceived();
        s.vaultTotalReleasedQuote = vault.totalReleased();
        s.vaultPendingQuote = vault.pendingQuote();
        s.engineUnallocatedQuote = engine.unallocatedQuote();
        s.cumulativeQuoteProcessed = engine.cumulativeQuoteProcessed();
        s.trackerTotalShares = tracker.totalShares();
        s.trackerMinimumShare = tracker.minimumShareBalance();
        s.distributorPhase = uint8(distributor.phase());
        s.currentCycleId = distributor.cycleId();
        s.assetCount = engine.assetsCount();
    }

    /// @dev one card per engine-registered asset; disabled assets stay visible
    /// forever (zero-weight-over-removal requirement — legacy data never vanishes).
    function assetCards() public view returns (AssetCard[] memory cards) {
        uint256 n = engine.assetsCount();
        cards = new AssetCard[](n);
        for (uint256 i; i < n; ++i) {
            address a = engine.allAssets(i);
            (, bool enE, uint16 w, uint128 cap) = engine.assets(a);
            (, bool enD) = distributor.assetInfo(a);
            cards[i] = AssetCard({
                asset: a,
                enabledEngine: enE,
                enabledDistributor: enD,
                weightBps: w,
                maxSpendPerBuy: cap,
                budgetQuote: engine.budget(a),
                cumulativeSpentQuote: engine.cumulativeSpent(a),
                cumulativeBoughtRaw: engine.cumulativeBought(a),
                cumulativeDistributedRaw: distributor.cumulativeDistributed(a),
                distributorBalanceRaw: IERC20(a).balanceOf(address(distributor)),
                reservedForAccruedRaw: distributor.reservedForAccrued(a),
                minPayoutRaw: distributor.minPayout(a)
            });
        }
    }

    function holderCard(address h) external view returns (HolderCard memory c) {
        (uint256 share,,) = tracker.userInfo(h);
        c.trackerShare = share;
        c.excluded = tracker.excludedFromDividends(h);
        uint256 n = engine.assetsCount();
        c.accruedRaw = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            c.accruedRaw[i] = distributor.accrued(engine.allAssets(i), h);
        }
    }

    /// @notice Keeper helper: flushable = accrued dust above the payout gate.
    function flushable(address h) external view returns (address[] memory assets_, uint256[] memory amounts) {
        uint256 n = engine.assetsCount();
        assets_ = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address a = engine.allAssets(i);
            uint256 owed = distributor.accrued(a, h);
            if (owed >= distributor.minPayout(a) && owed > 0) {
                assets_[i] = a;
                amounts[i] = owed;
            }
        }
    }
}