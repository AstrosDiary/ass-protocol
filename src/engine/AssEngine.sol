// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IWBNB} from "../interfaces/IWBNB.sol";
import {AssSwapExecutor} from "../adapters/AssSwapExecutor.sol";

/// @title AssEngine — revenue processing and basket budgeting for $ASS
/// @notice Receives BNB from AssVault, wraps to WBNB, splits by basket weights
/// into per-asset budgets, and executes keeper-priced buys through the
/// SwapExecutor with bStocks landing directly in the Distributor. A failed or
/// skipped asset's budget simply persists — carry-forward is the default state,
/// not an exception path. All accounting in raw units.
contract AssEngine is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IWBNB public immutable wbnb;
    AssSwapExecutor public executor;
    address public distributor;
    mapping(address => bool) public keeper;

    struct Asset {
        bool registered;
        bool enabled;        // disabled = no NEW budget; existing budget stays spendable/reassignable
        uint16 weightBps;    // zero-weight preferred over removal (stored requirement)
        uint128 maxSpendPerBuy; // per-tx WBNB cap — bounds keeper blast radius + forces batching
    }

    address[] public allAssets;
    mapping(address => Asset) public assets;
    mapping(address => uint256) public budget; // WBNB earmarked per asset (carry-forward lives here)
    uint16 public totalWeightBps;

    uint256 public minProcessAmount = 0.05 ether; // don't churn dust cycles
    uint256 public cumulativeBnbProcessed;
    mapping(address => uint256) public cumulativeSpent;  // WBNB per asset
    mapping(address => uint256) public cumulativeBought; // bStock raw units per asset

    event KeeperSet(address indexed k, bool on);
    event ExecutorSet(address indexed executor);
    event DistributorSet(address indexed distributor);
    event AssetAdded(address indexed asset, uint16 weightBps, uint128 maxSpendPerBuy);
    event AssetConfigured(address indexed asset, bool enabled, uint16 weightBps, uint128 maxSpendPerBuy);
    event RevenueProcessed(uint256 bnbWrapped, uint256 allocated, uint256 unallocatedCarry);
    event Bought(address indexed asset, address indexed router, uint256 wbnbSpent, uint256 received);
    event BuyFailed(address indexed asset, address indexed router, uint256 attemptedSpend, bytes reason);
    event BudgetReassigned(address indexed from, address indexed to, uint256 amount);

    error NotKeeper();
    error UnknownAsset();
    error AssetRegistered();
    error AssetDisabled();
    error WeightsTooHigh();
    error NothingToProcess();
    error OverBudget();
    error OverMaxSpend();
    error NotSelf();

    modifier onlyKeeper() {
        if (!keeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(address wbnb_, address owner_) Ownable(owner_) {
        wbnb = IWBNB(wbnb_);
    }

    receive() external payable {} // BNB arrives from AssVault.release()

    // ---------------------------------------------------------------- admin
    function setKeeper(address k, bool on) external onlyOwner { keeper[k] = on; emit KeeperSet(k, on); }
    function setExecutor(address e) external onlyOwner { executor = AssSwapExecutor(e); emit ExecutorSet(e); }
    function setDistributor(address d) external onlyOwner { distributor = d; emit DistributorSet(d); }
    function setMinProcessAmount(uint256 v) external onlyOwner { minProcessAmount = v; }

    function addAsset(address asset, uint16 weightBps, uint128 maxSpendPerBuy) external onlyOwner {
        if (assets[asset].registered) revert AssetRegistered();
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
    /// @notice Wrap accumulated BNB and split by weights into per-asset budgets.
    /// weightBps is absolute (sum <= 10000); any shortfall from rounding or
    /// sub-10000 weights stays as unallocated WBNB and rolls into the next call.
    function processRevenue() external onlyKeeper nonReentrant {
        uint256 bal = address(this).balance;
        if (bal < minProcessAmount) revert NothingToProcess();
        wbnb.deposit{value: bal}();
        cumulativeBnbProcessed += bal;

        uint256 allocated;
        for (uint256 i; i < allAssets.length; ++i) {
            Asset memory a = assets[allAssets[i]];
            if (!a.enabled || a.weightBps == 0) continue;
            uint256 slice = (bal * a.weightBps) / 10_000;
            if (slice == 0) continue;
            budget[allAssets[i]] += slice;
            allocated += slice;
        }
        emit RevenueProcessed(bal, allocated, bal - allocated);
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
        IERC20(address(wbnb)).safeTransfer(address(executor), spend);
        (spent, received) = executor.execute(
            router, routerCalldata, spend, asset, minOut, distributor, deadline
        );
        // executor returns leftovers to this contract; anything unspent simply
        // remains in our WBNB balance and stays counted inside budget[asset]
        // because we only decrement by `spent`.
    }

    // ---------------------------------------------------------------- views
    function assetsCount() external view returns (uint256) { return allAssets.length; }
    function unallocatedWbnb() public view returns (uint256) {
        uint256 earmarked;
        for (uint256 i; i < allAssets.length; ++i) earmarked += budget[allAssets[i]];
        uint256 bal = wbnb.balanceOf(address(this));
        return bal > earmarked ? bal - earmarked : 0;
    }
}