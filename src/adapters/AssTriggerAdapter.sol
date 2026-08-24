// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlapTriggerService, ITriggerReceiver} from "../flap/IFlapTriggerService.sol";
import {AssEngine} from "../engine/AssEngine.sol";
import {V3Twap} from "../libraries/V3Twap.sol";

interface IAssVaultOps {
    function pendingQuote() external view returns (uint256);
    function release() external;
}

interface IWBNBMinimal {
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

interface IProcessable {
    function processReceived() external returns (uint256);
}

/// @title AssTriggerAdapter — Flap Trigger Service automation for the $ASS swap pipeline
/// @notice Self-perpetuating cycle: a CYCLE trigger releases vault revenue,
/// processes it into budgets, spawns one capped BUY trigger per fundable asset,
/// and re-arms itself at +interval. BUY triggers price on-chain via Pancake V3
/// TWAP and execute through the existing engine/executor invariants.
/// DOCTRINE: trigger() NEVER reverts — every path re-validates live state and
/// fails soft (event + return), so a stale/late callback can never wedge the
/// pipeline and the FAILED/retry path is never load-bearing. The manual keeper
/// retains all roles as a full fallback: automation lapsing degrades to
/// keeper-driven operation, never to a halt.
/// Fees are funded from tax revenue: the engine skims gasFundBps of processed
/// QQQB to this adapter, which tops up native BNB via a TWAP-bounded
/// QQQB->WBNB swap + unwrap.
/// @dev Beacon-upgradeable per Flap satellite doctrine: Guardian owns the
/// beacon and is a parallel emergency caller on admin (onlyOwnerOrGuardian).
/// The vault is set post-launch (setVault) — it does not exist at satellite
/// deploy time; an unset vault only skips the release step, never reverts.
contract AssTriggerAdapter is Initializable, OwnableUpgradeable, ReentrancyGuard, ITriggerReceiver {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- config
    IFlapTriggerService public triggerService;
    AssEngine public engine;
    IAssVaultOps public vault;          // set post-launch via setVault
    IERC20 public quote;                // QQQB
    address public wbnb;

    /// @dev SmartRouter exactInput takes ONE struct argument; encoding it as
    /// flat args drops the tuple's leading offset word and the router reverts
    /// undecodable (incident: 12x RouterCallFailed(empty), 2026-08-22).
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }

    struct Route { address[] pools; address[] tokens; bytes path; }
    mapping(address => Route) internal _routes;   // basket asset => QQQB->asset route
    Route internal _gasRoute;                     // QQQB->WBNB route (fee funding)

    address public swapRouter;          // allowlisted SmartRouter (matches executor allowlist)
    uint64  public cycleInterval;       // seconds between CYCLE triggers
    uint32  public twapWindow;          // TWAP lookback
    uint16  public slippageBps;         // tolerance off TWAP
    uint256 public buyMinQuote;         // skip dust budgets
    uint256 public feeFloor;            // keep >= this much BNB banked
    uint256 public gasSwapMin;          // min QQQB worth converting to gas
    bool    public paused;              // pause = stop self-rescheduling (fallback to keeper)

    // ---------------------------------------------------------------- actions
    enum Kind { NONE, CYCLE, BUY }
    struct Pending { Kind kind; address asset; }
    mapping(uint256 => Pending) public pending;   // requestId => action (consumed on execute)

    // ---------------------------------------------------------------- events
    event CycleScheduled(uint256 indexed requestId, uint64 executeAfter);
    event BuyScheduled(uint256 indexed requestId, address indexed asset);
    event Triggered(uint256 indexed requestId, Kind kind, address asset);
    event Skipped(uint256 indexed requestId, string reason);
    event BuyExecuted(address indexed asset, uint256 spend, uint256 minOut, bool ok);
    event GasToppedUp(uint256 quoteIn, uint256 bnbOut);
    event FundingLow(uint256 balance, uint256 feeNeeded);
    event RouteSet(address indexed asset);
    event VaultSet(address indexed vault);
    event PausedSet(bool paused);

    error OnlyTriggerService();
    error LengthMismatch();
    error Unauthorized();
    error UnsupportedChain(uint256 chainId);

    // ---------------------------------------------------------- guardian mandate
    function _getGuardian() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (chainId == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        if (chainId == 4663 || chainId == 46630) return 0x0000b48720d3B4ED6BC5031768B07F2b59270000;
        revert UnsupportedChain(chainId);
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != _getGuardian()) revert Unauthorized();
        _;
    }

    constructor() { _disableInitializers(); }

    function initialize(address triggerService_, address engine_, address wbnb_, address owner_)
        external
        initializer
    {
        require(triggerService_ != address(0) && engine_ != address(0) && wbnb_ != address(0), "zero addr");
        __Ownable_init(owner_);
        triggerService = IFlapTriggerService(triggerService_);
        engine = AssEngine(engine_);
        quote = AssEngine(engine_).quote();
        wbnb = wbnb_;

        // proxy-safe defaults (declaration-site defaults don't run under proxies)
        cycleInterval = 900;            // 15 min
        twapWindow = 300;               // 5 min TWAP
        slippageBps = 150;              // 1.5%
        buyMinQuote = 0.005 ether;      // QQQB raw units
        feeFloor = 0.01 ether;          // BNB
        gasSwapMin = 0.01 ether;        // QQQB raw units
    }

    /// @notice gas tank: open receive (BNB only ever funds trigger fees; sweepable by owner)
    receive() external payable {}

    // ---------------------------------------------------------------- admin
    /// @notice launch-coupled wiring: the vault exists only after token launch
    function setVault(address v) external onlyOwnerOrGuardian {
        vault = IAssVaultOps(v);
        emit VaultSet(v);
    }

    function setRoute(address asset, address[] calldata pools, address[] calldata tokens, bytes calldata path)
        external onlyOwnerOrGuardian
    {
        if (tokens.length != pools.length + 1) revert LengthMismatch();
        require(tokens[0] == address(quote), "route must start at quote");
        _routes[asset] = Route(pools, tokens, path);
        emit RouteSet(asset);
    }

    function setGasRoute(address[] calldata pools, address[] calldata tokens, bytes calldata path)
        external onlyOwnerOrGuardian
    {
        if (tokens.length != pools.length + 1) revert LengthMismatch();
        require(tokens[0] == address(quote) && tokens[tokens.length - 1] == wbnb, "quote->wbnb only");
        _gasRoute = Route(pools, tokens, path);
    }

    function setSwapRouter(address r) external onlyOwnerOrGuardian { swapRouter = r; }

    function setParams(uint64 interval_, uint32 window_, uint16 slipBps_, uint256 buyMin_, uint256 feeFloor_, uint256 gasSwapMin_)
        external onlyOwnerOrGuardian
    {
        require(slipBps_ <= 2_000 && window_ >= 60, "params");
        cycleInterval = interval_; twapWindow = window_; slippageBps = slipBps_;
        buyMinQuote = buyMin_; feeFloor = feeFloor_; gasSwapMin = gasSwapMin_;
    }

    function setPaused(bool p) external onlyOwnerOrGuardian { paused = p; emit PausedSet(p); }
    function sweepBnb(address to, uint256 amt) external onlyOwnerOrGuardian { (bool ok,) = to.call{value: amt}(""); require(ok); }
    function sweepToken(address t, address to) external onlyOwnerOrGuardian { IERC20(t).safeTransfer(to, IERC20(t).balanceOf(address(this))); }

    /// @notice kick-start (or manually re-arm) the self-perpetuating cycle.
    /// @param delay seconds from now (0 = ASAP)
    /// @dev Reverts on an empty gas tank: for the owner-facing entry point a
    /// silent no-op would hide a dead scheduler. The INTERNAL self-rearm path
    /// (_requestCycle from trigger()) deliberately stays non-reverting instead
    /// (fail-soft doctrine): a drained tank lapses automation loudly via
    /// FundingLow and falls back to the manual keeper — it never wedges a
    /// callback.
    function scheduleCycle(uint64 delay) external onlyOwnerOrGuardian returns (uint256 id) {
        id = _requestCycle(delay == 0 ? 0 : uint64(block.timestamp) + delay);
        require(id != type(uint256).max, "insufficient BNB for fee");
    }

    // ---------------------------------------------------------------- callback
    /// @inheritdoc ITriggerReceiver
    function trigger(uint256 requestId) external override nonReentrant {
        if (msg.sender != address(triggerService)) revert OnlyTriggerService(); // MANDATORY sender check
        Pending memory p = pending[requestId];
        delete pending[requestId];                                              // consume: no replay
        if (p.kind == Kind.NONE) { emit Skipped(requestId, "unknown/consumed id"); return; }
        emit Triggered(requestId, p.kind, p.asset);

        if (p.kind == Kind.CYCLE) _runCycle(requestId);
        else _runBuy(requestId, p.asset);
    }

    // ---------------------------------------------------------------- cycle step
    function _runCycle(uint256 requestId) internal {
        // advance the basket: mint+deposit anything last cycle's buys delivered
        // (permissionless on the basket; fail-soft here — NothingToProcess is
        // the normal empty-cycle case). Code check: a call to a code-less
        // address would "succeed" with empty returndata and the uint256 decode
        // would revert in OUR frame, outside try/catch protection.
        address basketDist = engine.distributor();
        if (basketDist.code.length > 0) {
            try IProcessable(basketDist).processReceived() {} catch {}
        }
        _topUpGas();

        // release: re-validated live; unset vault = skip; vault reverts fail soft
        if (address(vault) != address(0) && vault.pendingQuote() > 0) {
            try vault.release() {} catch { emit Skipped(requestId, "release failed"); }
        }
        // process: engine enforces its own floor; only call when it would pass
        if (engine.unallocatedQuote() >= engine.minProcessAmount()) {
            try engine.processRevenue() {} catch { emit Skipped(requestId, "process failed"); }
        }
        // spawn one BUY trigger per fundable, routed asset
        uint256 n = engine.assetsCount();
        for (uint256 i; i < n && i < 8; ++i) {
            address a = engine.allAssets(i);
            if (engine.budget(a) < buyMinQuote) continue;
            if (_routes[a].pools.length == 0) continue;
            uint256 fee = triggerService.getFee();
            if (address(this).balance < fee + feeFloor) { emit FundingLow(address(this).balance, fee); break; }
            uint256 id = triggerService.requestTrigger{value: fee}(0); // ASAP
            pending[id] = Pending(Kind.BUY, a);
            emit BuyScheduled(id, a);
        }
        // self-perpetuate (unless paused) — automation lapses loudly, never wedges
        if (!paused) {
            if (_requestCycle(uint64(block.timestamp) + cycleInterval) == type(uint256).max) {
                emit FundingLow(address(this).balance, triggerService.getFee());
            }
        }
    }

    function _requestCycle(uint64 executeAfter) internal returns (uint256 id) {
        uint256 fee = triggerService.getFee();
        if (address(this).balance < fee) return type(uint256).max;
        id = triggerService.requestTrigger{value: fee}(executeAfter);
        pending[id] = Pending(Kind.CYCLE, address(0));
        emit CycleScheduled(id, executeAfter);
    }

    // ---------------------------------------------------------------- buy step
    function _runBuy(uint256 requestId, address asset) internal {
        Route memory r = _routes[asset];
        if (r.pools.length == 0) { emit Skipped(requestId, "no route"); return; }
        uint256 spend = engine.budget(asset);           // re-validate LIVE (delay-aware)
        (, , , uint128 cap) = engine.assets(asset);
        if (cap != 0 && spend > cap) spend = cap;       // engine would reject over-cap anyway
        if (spend < buyMinQuote) { emit Skipped(requestId, "budget below min"); return; }

        uint256 minOut;
        try this.twapQuoteExt(asset, spend) returns (uint256 q) { minOut = (q * (10_000 - slippageBps)) / 10_000; }
        catch { emit Skipped(requestId, "twap unavailable"); return; }  // uninitialized oracle etc: carry forward
        if (minOut == 0) { emit Skipped(requestId, "zero twap quote"); return; }

        bytes memory cd = _routerCalldata(r.path, spend, minOut);
        bool ok = engine.executeBuy(asset, swapRouter, cd, spend, minOut, block.timestamp + 600);
        emit BuyExecuted(asset, spend, minOut, ok);     // ok=false => engine isolated it; budget carried
    }

    /// @dev external wrapper so TWAP reverts (uninitialized observations) are catchable
    function twapQuoteExt(address asset, uint256 amountIn) external view returns (uint256) {
        Route memory r = _routes[asset];
        return V3Twap.quoteRoute(r.pools, r.tokens, twapWindow, amountIn);
    }

    function _routerCalldata(bytes memory path, uint256 amountIn, uint256 minOut) internal view returns (bytes memory) {
        bytes memory inner = abi.encodeWithSelector(
            0xb858183f, ExactInputParams(path, address(engine.executor()), amountIn, minOut)
        );
        bytes[] memory calls = new bytes[](1);
        calls[0] = inner;
        return abi.encodeWithSelector(0x5ae401dc, block.timestamp + 600, calls);
    }

    // ---------------------------------------------------------------- gas funding
    /// @dev QQQB (engine skim) -> WBNB -> unwrap, only when float is low. TWAP-bounded
    /// like every other swap; failure is soft (skip — next cycle retries).
    function _topUpGas() internal {
        if (address(this).balance >= feeFloor) return;
        Route memory g = _gasRoute;
        if (g.pools.length == 0 || swapRouter == address(0)) return;
        uint256 bal = quote.balanceOf(address(this));
        if (bal < gasSwapMin) return;

        uint256 minOut;
        try this.gasTwapQuoteExt(bal) returns (uint256 q) { minOut = (q * (10_000 - slippageBps)) / 10_000; }
        catch { return; }
        if (minOut == 0) return;

        quote.forceApprove(swapRouter, bal);
                bytes memory inner = abi.encodeWithSelector(0xb858183f, ExactInputParams(g.path, address(this), bal, minOut));
        bytes[] memory calls = new bytes[](1); calls[0] = inner;
        (bool ok,) = swapRouter.call(abi.encodeWithSelector(0x5ae401dc, block.timestamp + 600, calls));
        quote.forceApprove(swapRouter, 0);
        if (!ok) return;

        uint256 w = IWBNBMinimal(wbnb).balanceOf(address(this));
        if (w > 0) { IWBNBMinimal(wbnb).withdraw(w); emit GasToppedUp(bal, w); }
    }

    function gasTwapQuoteExt(uint256 amountIn) external view returns (uint256) {
        Route memory g = _gasRoute;
        return V3Twap.quoteRoute(g.pools, g.tokens, twapWindow, amountIn);
    }
}