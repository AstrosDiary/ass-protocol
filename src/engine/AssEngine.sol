// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {AssSwapExecutor} from "../adapters/AssSwapExecutor.sol";

/// @title AssEngine — revenue processing and basket budgeting for $ASS
/// @notice Receives QQQB (quote token) from AssVault, splits it by basket
/// weights into per-asset budgets, and executes keeper-priced buys through the
/// SwapExecutor with bStocks landing directly in the Distributor. A failed or
/// skipped asset's budget simply persists — carry-forward is the default state,
/// not an exception path. All accounting in raw units.
/// @dev Inflow and budgets share one ERC20 balance, so processing takes only
/// the unearmarked portion: balance minus outstanding budgets. No native BNB
/// path exists anywhere (no receive/fallback).
contract AssEngine is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable quote; // QQQB — Invesco QQQ Trust bStock
    AssSwapExecutor public executor;
    address public distributor;
    mapping(address => bool) public keeper;

    struct Asset {
        bool registered;
        bool enabled;        // disabled = no NEW budget; existing budget stays spendable/reassignable
        uint16 weightBps;    // zero-weight preferred over removal (stored requirement)
        uint128 maxSpendPerBuy; // per-tx quote cap — bounds keeper blast radius + forces batching
    }

    address[] public allAssets;
    mapping(address => Asset) public assets;
    mapping(address => uint256) public budget; // quote earmarked per asset (carry-forward lives here)
    uint16 public totalWeightBps;

    uint256 public minProcessAmount = 0.05 ether; // QQQB raw units — don't churn dust cycles
    uint256 public cumulativeQuoteProcessed;      // Σ allocated to budgets (never double-counts)
    mapping(address => uint256) public cumulativeSpent;  // quote per asset
    mapping(address => uint256) public cumulativeBought; // bStock raw units per asset

    event KeeperSet(address indexed k, bool on);
    event ExecutorSet(address indexed executor);
    event DistributorSet(address indexed distributor);
    event AssetAdded(address indexed asset, uint16 weightBps, uint128 maxSpendPerBuy);
    event AssetConfigured(address indexed asset, bool enabled, uint16 weightBps, uint128 maxSpendPerBuy);
    event RevenueProcessed(uint256 quoteIn, uint256 allocated, uint256 unallocatedCarry);
    event Bought(address indexed asset, address indexed router, uint256 quoteSpent, uint256 received);
    event BuyFailed(address indexed asset, address indexed router, uint256 attemptedSpend, bytes reason);
    event BudgetReassigned(address indexed from, address indexed to, uint256 amount);

    error NotKeeper();
    error UnknownAsset();
    error AssetRegistered();
    error AssetDisabled();
    error AssetIsQuote();
    error WeightsTooHigh();
    error NothingToProcess();
    error OverBudget();
    error OverMaxSpend();
    error NotSelf();

    modifier onlyKeeper() {
        if (!keeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(address quote_, address owner_) Ownable(owner_) {
        require(quote_ != address(0) && quote_.code.length > 0, "bad quote");
        quote = IERC20(quote_);
    }

    // ---------------------------------------------------------------- admin
    function setKeeper(address k, bool on) external onlyOwner { keeper[k] = on; emit KeeperSet(k, on); }
    function setExecutor(address e) external onlyOwner { executor = AssSwapExecutor(e); emit ExecutorSet(e); }
    function setDistributor(address d) external onlyOwner { distributor = d; emit DistributorSet(d); }
    function setMinProcessAmount(uint256 v) external onlyOwner { minProcessAmount = v; }

    function addAsset(address asset, uint16 weightBps, uint128 maxSpendPerBuy) external onlyOwner {
        if (assets[asset].registered) revert AssetRegistered();
        if (asset == address(quote)) revert AssetIsQuote(); // basket asset can never be the quote
        require(asset != address(0) && asset.code.length > 0, "bad asset");
        IERC20(asset).balanceOf(address(this)); // must quack like ERC-20
        if (totalWeightBps + weightBps > 10_000) revert WeightsTooHigh();
        totalWeightBps += weightBps;
        assets[asset] = Asset(true, true, weightBps, maxSpendPerBuy);
        allAssets.push(asset);
        emit AssetAdded(asset, weightBps, maxSpendPerBuy);
    }

    /// @dev enable/disable, reweight, retune spend cap — never removal.
    function configureAsset(address asset, bool enabled, uint16 weightBps, uint128 maxSpendPerBuy)
        external
        onlyOwner
    {
        Asset storage a = assets[asset];
        if (!a.registered) revert UnknownAsset();
        uint16 newTotal = totalWeightBps - a.weightBps + weightBps;
        if (newTotal > 10_000) revert WeightsTooHigh();
        totalWeightBps = newTotal;
        a.enabled = enabled;
        a.weightBps = weightBps;
        a.maxSpendPerBuy = maxSpendPerBuy;
        emit AssetConfigured(asset, enabled, weightBps, maxSpendPerBuy);
    }

    /// @notice Manual carry-forward control: move a stuck asset's budget to a
    /// routable one (e.g. prolonged corporate-action pause). Keeper-gated,
    /// registered assets only — funds can never leave the basket system.
    function reassignBudget(address from, address to, uint256 amount) external onlyKeeper {
        if (!assets[from].registered || !assets[to].registered) revert UnknownAsset();
        if (!assets[to].enabled) revert AssetDisabled();
        if (amount > budget[from]) revert OverBudget();
        budget[from] -= amount;
        budget[to] += amount;
        emit BudgetReassigned(from, to, amount);
    }

    // ---------------------------------------------------------------- cycle
    /// @notice Split newly-arrived quote (balance minus outstanding budgets) by
    /// weights into per-asset budgets. weightBps is absolute (sum <= 10000);
    /// rounding dust stays unearmarked and rolls into the next call.
    function processRevenue() external onlyKeeper nonReentrant {
        uint256 unprocessed = _unallocated();
        if (unprocessed < minProcessAmount) revert NothingToProcess();

        uint256 allocated;
        for (uint256 i; i < allAssets.length; ++i) {
            Asset memory a = assets[allAssets[i]];
            if (!a.enabled || a.weightBps == 0) continue;
            uint256 slice = (unprocessed * a.weightBps) / 10_000;
            if (slice == 0) continue;
            budget[allAssets[i]] += slice;
            allocated += slice;
        }
        cumulativeQuoteProcessed += allocated; // only what entered budgets — double-count impossible
        emit RevenueProcessed(unprocessed, allocated, unprocessed - allocated);
    }

    /// @notice Execute one keeper-priced buy. Failure is isolated: the external
    /// self-call reverts atomically (approval/transfer state fully unwound),
    /// we emit BuyFailed, and the asset's budget carries forward untouched.
    function executeBuy(
        address asset,
        address router,
        bytes calldata routerCalldata,
        uint256 spend,
        uint256 minOut,
        uint256 deadline
    ) external onlyKeeper nonReentrant returns (bool ok) {
        Asset memory a = assets[asset];
        if (!a.registered) revert UnknownAsset();
        if (!a.enabled) revert AssetDisabled();
        if (spend > budget[asset]) revert OverBudget();
        if (spend > a.maxSpendPerBuy) revert OverMaxSpend();

        try this.buySelf(asset, router, routerCalldata, spend, minOut, deadline)
            returns (uint256 spent, uint256 received)
        {
            budget[asset] -= spent;
            cumulativeSpent[asset] += spent;
            cumulativeBought[asset] += received;
            emit Bought(asset, router, spent, received);
            return true;
        } catch (bytes memory reason) {
            emit BuyFailed(asset, router, spend, reason);
            return false;
        }
    }

    /// @dev external-only self-call target so a failed buy reverts as a unit
    /// (INDEX isolation pattern). Not callable by anyone else.
    function buySelf(
        address asset,
        address router,
        bytes calldata routerCalldata,
        uint256 spend,
        uint256 minOut,
        uint256 deadline
    ) external returns (uint256 spent, uint256 received) {
        if (msg.sender != address(this)) revert NotSelf();
        quote.safeTransfer(address(executor), spend);
        (spent, received) = executor.execute(
            router, routerCalldata, spend, asset, minOut, distributor, deadline
        );
        // executor returns leftovers to this contract; anything unspent simply
        // remains in our quote balance and stays counted inside budget[asset]
        // because we only decrement by `spent`.
    }

    // ---------------------------------------------------------------- views
    function assetsCount() external view returns (uint256) { return allAssets.length; }

    /// @notice Quote held that is not earmarked to any asset budget —
    /// i.e. revenue awaiting processRevenue, plus rounding dust.
    function unallocatedQuote() external view returns (uint256) { return _unallocated(); }

    function _unallocated() internal view returns (uint256) {
        uint256 earmarked;
        for (uint256 i; i < allAssets.length; ++i) earmarked += budget[allAssets[i]];
        uint256 bal = quote.balanceOf(address(this));
        return bal > earmarked ? bal - earmarked : 0;
    }
}