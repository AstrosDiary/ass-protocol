// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlapDividend} from "../interfaces/IFlapDividend.sol";

/// @title AssDistributor — multi-asset (bStock) reward distributor for $ASS
/// @notice INDEX-pattern keeper-gated cycles. Holder shares come from Flap's
/// Dividend tracker (tracker-only mode): keeper submits the holder set indexed
/// off FlapDividendShareChanged; this contract verifies every share LIVE via
/// userInfo(), reconciles coverage against totalShares(), and pays
/// min(snapshotShare, liveShare) — flash/transfer-games can only reduce a payout.
/// All amounts are RAW on-chain units (BEP-677: multiplier is display-layer only).
/// @dev Beacon-upgradeable per Flap satellite doctrine: Guardian owns the
/// beacon and is a parallel emergency caller on admin (onlyOwnerOrGuardian).
contract AssDistributor is Initializable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- roles
    mapping(address => bool) public keeper;
    IFlapDividend public dividendTracker; // set post-launch (Flap deploys it with the token)

    // ---------------------------------------------------------------- assets
    struct AssetInfo { bool registered; bool enabled; }
    address[] public allAssets;
    mapping(address => AssetInfo) public assetInfo;
    mapping(address => uint256) public minPayout;           // raw units, per asset (dust gate)
    mapping(address => uint256) public reservedForAccrued;  // sum of all accrued[asset][*]
    mapping(address => mapping(address => uint256)) public accrued; // asset => holder => owed

    // ---------------------------------------------------------------- cycles
    enum Phase { Idle, Snapshot, Payout }
    struct Entry { address holder; uint96 share; }

    Phase   public phase;
    uint64  public cycleId;
    uint256 public totalSnapShares;
    uint256 public payoutCursor;
    address public lastSubmitted;        // enforces ascending submission => no duplicates
    uint16  public coverageBps;          // snapshot must cover >= this share of tracker totalShares()

    mapping(uint64 => Entry[])   internal _entries;
    mapping(uint64 => address[]) internal _cycleAssets;
    mapping(uint64 => mapping(address => uint256)) public cyclePot; // raw units

    // ---------------------------------------------------------------- stats
    mapping(address => uint256) public cumulativeDistributed; // per asset, raw

    // ---------------------------------------------------------------- events
    event KeeperSet(address indexed k, bool on);
    event DividendTrackerSet(address indexed tracker);
    event AssetAdded(address indexed asset);
    event AssetEnabled(address indexed asset, bool enabled);
    event MinPayoutSet(address indexed asset, uint256 amount);
    event CoverageSet(uint16 bps);
    event CycleStarted(uint64 indexed id);
    event HoldersSubmitted(uint64 indexed id, uint256 count, uint256 totalSnapShares);
    event CycleFinalized(uint64 indexed id, uint256 totalSnapShares, uint256 assetCount);
    event CycleCompleted(uint64 indexed id);
    event CycleAborted(uint64 indexed id);
    event Paid(uint64 indexed id, address indexed asset, address indexed holder, uint256 amount);
    event Accruedd(uint64 indexed id, address indexed asset, address indexed holder, uint256 amount);
    event SendFailed(uint64 indexed id, address indexed asset, address indexed holder, uint256 amount);
    event AccruedClaimed(address indexed asset, address indexed holder, uint256 amount);
    event SweptForeign(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------- errors
    error NotKeeper();
    error WrongPhase();
    error TrackerNotSet();
    error NotAscending();
    error ShareOverflow();
    error CoverageTooLow(uint256 have, uint256 need);
    error UnknownAsset();
    error AssetIsRegistered();
    error NothingOwed();
    error BelowMinPayout();
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

    modifier onlyKeeper() {
        if (!keeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor() { _disableInitializers(); }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        coverageBps = 9_000; // proxy-safe default (declaration-site defaults don't run under proxies)
    }

    // ================================================================ admin
    function setKeeper(address k, bool on) external onlyOwnerOrGuardian { keeper[k] = on; emit KeeperSet(k, on); }

    function setDividendTracker(address t) external onlyOwnerOrGuardian {
        require(t.code.length > 0, "no code");
        IFlapDividend(t).totalShares(); // must respond like a tracker
        dividendTracker = IFlapDividend(t);
        emit DividendTrackerSet(t);
    }

    function setCoverageBps(uint16 bps) external onlyOwnerOrGuardian {
        require(bps <= 10_000, "bps");
        coverageBps = bps;
        emit CoverageSet(bps);
    }

    /// @dev keeper-updatable per the BEP-677 ruling: dust gate is an ECONOMIC
    /// threshold, so it gets recalculated off-chain when multipliers change.
    function setMinPayout(address asset, uint256 amount) external onlyKeeper {
        if (!assetInfo[asset].registered) revert UnknownAsset();
        minPayout[asset] = amount;
        emit MinPayoutSet(asset, amount);
    }

    function addAsset(address asset) external onlyOwnerOrGuardian {
        if (assetInfo[asset].registered) revert AssetIsRegistered();
        require(asset != address(0) && asset.code.length > 0, "bad asset");
        IERC20(asset).balanceOf(address(this)); // must behave like ERC-20
        assetInfo[asset] = AssetInfo(true, true);
        allAssets.push(asset);
        emit AssetAdded(asset);
    }

    /// @dev disable = excluded from NEW cycles. Accrued balances stay claimable
    /// forever; registered assets are never sweepable. (Zero-weight-over-removal.)
    function setAssetEnabled(address asset, bool enabled) external onlyOwnerOrGuardian {
        if (!assetInfo[asset].registered) revert UnknownAsset();
        assetInfo[asset].enabled = enabled;
        emit AssetEnabled(asset, enabled);
    }

    function sweepForeign(address token, address to) external onlyOwnerOrGuardian {
        require(!assetInfo[token].registered, "registered asset"); // forever barred
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit SweptForeign(token, to, bal);
    }

    // ================================================================ cycle
    function startCycle() external onlyKeeper {
        if (phase != Phase.Idle) revert WrongPhase();
        if (address(dividendTracker) == address(0)) revert TrackerNotSet();
        unchecked { cycleId++; }
        phase = Phase.Snapshot;
        totalSnapShares = 0;
        payoutCursor = 0;
        lastSubmitted = address(0);
        emit CycleStarted(cycleId);
    }

    /// @notice Keeper submits holders in STRICTLY ASCENDING address order
    /// (cheap on-chain duplicate prevention). Shares are read LIVE from the
    /// Flap tracker at submission — the keeper supplies only addresses, never
    /// amounts, so a malicious keeper cannot inflate anyone's entitlement.
    function submitHolders(address[] calldata hs) external onlyKeeper {
        if (phase != Phase.Snapshot) revert WrongPhase();
        address last = lastSubmitted;
        Entry[] storage entries = _entries[cycleId];
        uint256 added;
        uint256 sharesAdded;
        for (uint256 i; i < hs.length; ++i) {
            address h = hs[i];
            if (h <= last) revert NotAscending();
            last = h;
            (uint256 share,,) = dividendTracker.userInfo(h);
            if (share == 0) continue; // excluded / below Flap minimum — tracker's call
            if (share > type(uint96).max) revert ShareOverflow();
            // uint96 max (~7.9e28) exceeds max possible share ($ASS total
            // supply = 1e27 raw), and the ShareOverflow guard above makes
            // truncation unreachable. (address,uint96) slot-packing per
            // Compound/Uniswap governance token precedent.
            // forge-lint: disable-next-line(unsafe-typecast)
            entries.push(Entry(h, uint96(share)));
            unchecked { added++; sharesAdded += share; }
        }
        lastSubmitted = last;
        totalSnapShares += sharesAdded;
        emit HoldersSubmitted(cycleId, added, totalSnapShares);
    }

    /// @notice Locks the holder set, checks coverage vs the tracker, and pots
    /// every enabled asset's UNRESERVED balance for this cycle.
    function finalizeSnapshot() external onlyKeeper {
        if (phase != Phase.Snapshot) revert WrongPhase();
        uint256 trackerTotal = dividendTracker.totalShares();
        uint256 need = (trackerTotal * coverageBps) / 10_000;
        if (totalSnapShares < need) revert CoverageTooLow(totalSnapShares, need);

        address[] storage cas = _cycleAssets[cycleId];
        for (uint256 i; i < allAssets.length; ++i) {
            address a = allAssets[i];
            if (!assetInfo[a].enabled) continue;
            uint256 pot = IERC20(a).balanceOf(address(this)) - reservedForAccrued[a];
            if (pot == 0) continue;
            cas.push(a);
            cyclePot[cycleId][a] = pot;
        }
        phase = Phase.Payout;
        emit CycleFinalized(cycleId, totalSnapShares, cas.length);
    }

    /// @notice Pays up to maxHolders entries. Per holder, per asset:
    /// entitlement = pot * min(snapShare, liveShare) / totalSnapShares.
    /// Below minPayout => accrues. Failed transfer => re-accrues, never reverts
    /// the batch (transfer-restricted bStock recipients get skipped safely).
    function pushPayouts(uint256 maxHolders) external onlyKeeper nonReentrant {
        if (phase != Phase.Payout) revert WrongPhase();
        Entry[] storage entries = _entries[cycleId];
        address[] storage cas = _cycleAssets[cycleId];
        uint256 end = payoutCursor + maxHolders;
        if (end > entries.length) end = entries.length;
        uint256 tss = totalSnapShares;
        uint64 id = cycleId;

        for (uint256 i = payoutCursor; i < end; ++i) {
            Entry memory e = entries[i];
            (uint256 live,,) = dividendTracker.userInfo(e.holder);
            uint256 eff = live < e.share ? live : e.share;
            for (uint256 j; j < cas.length; ++j) {
                address a = cas[j];
                uint256 amt = eff == 0 ? 0 : (cyclePot[id][a] * eff) / tss;
                uint256 prior = accrued[a][e.holder];
                uint256 owed = amt + prior;
                if (owed == 0) continue;
                if (owed < minPayout[a]) {
                    if (amt != 0) {
                        accrued[a][e.holder] = owed;
                        reservedForAccrued[a] += amt;
                        emit Accruedd(id, a, e.holder, amt);
                    }
                    continue;
                }
                // clear accrual bookkeeping optimistically, restore on failure
                if (prior != 0) { accrued[a][e.holder] = 0; reservedForAccrued[a] -= prior; }
                if (_trySend(a, e.holder, owed)) {
                    cumulativeDistributed[a] += owed;
                    emit Paid(id, a, e.holder, owed);
                } else {
                    accrued[a][e.holder] = owed;
                    reservedForAccrued[a] += owed;
                    emit SendFailed(id, a, e.holder, owed);
                }
            }
        }
        payoutCursor = end;
        if (end == entries.length) {
            phase = Phase.Idle;
            emit CycleCompleted(id);
        }
    }

    function abortCycle() external onlyKeeper {
        if (phase == Phase.Idle) revert WrongPhase();
        phase = Phase.Idle; // pots stay in balance and roll into the next cycle
        emit CycleAborted(cycleId);
    }

    // ================================================================ claims
    /// @notice Holder pulls their own accrued dust (any size — their gas).
    function claimAccrued(address asset) external nonReentrant {
        uint256 owed = accrued[asset][msg.sender];
        if (owed == 0) revert NothingOwed();
        accrued[asset][msg.sender] = 0;
        reservedForAccrued[asset] -= owed;
        IERC20(asset).safeTransfer(msg.sender, owed);
        cumulativeDistributed[asset] += owed;
        emit AccruedClaimed(asset, msg.sender, owed);
    }

    /// @notice Anyone can flush a holder's accrued once it clears the dust gate
    /// (keeper cron uses this — the Loxley withdraw-for pattern).
    function flushAccrued(address asset, address holder) external nonReentrant {
        uint256 owed = accrued[asset][holder];
        if (owed == 0) revert NothingOwed();
        if (owed < minPayout[asset]) revert BelowMinPayout();
        accrued[asset][holder] = 0;
        reservedForAccrued[asset] -= owed;
        if (_trySend(asset, holder, owed)) {
            cumulativeDistributed[asset] += owed;
            emit AccruedClaimed(asset, holder, owed);
        } else {
            accrued[asset][holder] = owed;
            reservedForAccrued[asset] += owed;
            emit SendFailed(cycleId, asset, holder, owed);
        }
    }

    // ================================================================ views
    function assetsCount() external view returns (uint256) { return allAssets.length; }
    function entriesCount(uint64 id) external view returns (uint256) { return _entries[id].length; }
    function entryAt(uint64 id, uint256 i) external view returns (address, uint96) {
        Entry memory e = _entries[id][i];
        return (e.holder, e.share);
    }
    function cycleAssets(uint64 id) external view returns (address[] memory) { return _cycleAssets[id]; }

    // ================================================================ internal
    /// @dev Non-reverting ERC-20 transfer: tolerates false-returners and
    /// reverters (restricted recipients). Success requires call success AND
    /// (no returndata OR decoded true).
    function _trySend(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}