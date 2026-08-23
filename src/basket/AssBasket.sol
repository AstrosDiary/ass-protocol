// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceHub} from "../interfaces/IPriceHub.sol";

interface IFlapTaxTokenDividendSource {
    function dividendContract() external view returns (address);
}

interface IFlapDividendDeposit {
    function deposit(uint256 amount) external returns (bool success);
}

interface IBStockMultiplier {
    function multiplier() external view returns (uint256);
}

/// @title AssBasket — Index Basket for Asian Stock Strategy (IB-ASS)
/// @notice Flap basket-token pattern (docs: basket-token-multi-asset-dividends):
/// an intermediate ERC20 representing a claim on pooled BABAB/TSMB/SKHYB,
/// used as the tax token's single `dividendToken`. Shares are minted against
/// LIVE oracle-priced USD NAV (Atlas Oracle multi-feed PriceHub, push mode)
/// and deposited into Flap's Dividend contract; claims auto-unwrap — this
/// token's transfer hook detects transfers FROM the dividend contract, burns
/// the shares, and releases the underlying bStocks pro-rata to the claimer.
/// Holders never see or hold this token.
/// PERMISSIONLESS PROCESSING: processReceived() mints+deposits against
/// balance-deltas and is callable by anyone (the TriggerAdapter pokes it;
/// nobody is trust-critical). All pooled accounting in raw units; BEP-677
/// display multipliers are consumed only inside oracle valuation.
/// @dev Beacon-upgradeable per Flap satellite doctrine (Guardian-owned beacon,
/// onlyOwnerOrGuardian parallel admin).
contract AssBasket is Initializable, OwnableUpgradeable, ERC20Upgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 1e15; // first-mint ratio lock (tutorial), minted to 0xdead
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------- config
    address public taxToken;                        // $ASS — set once post-launch
    IPriceHub public oracle;                        // Atlas PriceHub (multi-feed, push mode)
    uint8 public oracleDecimals;                    // hub-wide price precision (read at init; typically 18)
    address[] internal _subset;                     // component assets (fixed at init)
    mapping(address => bool) public isSupportedAsset;
    mapping(address => bytes4) public feedIdOf;     // component => Atlas feed id
    mapping(address => uint256) public accounted;   // component => processed balance baseline
    uint256 public maxFeedAge;                      // staleness bound on aggregatedTs (seconds)

    bool private _unwrapping;                       // guard: unwrap path never recurses

    // ---------------------------------------------------------------- events
    event TaxTokenSet(address indexed taxToken);
    event FeedSet(address indexed asset, bytes4 feedId);
    event MaxFeedAgeSet(uint256 age);
    event Minted(address indexed asset, uint256 amountIn, uint256 sharesOut, uint256 depositValueUsd);
    event DepositedToDividend(address indexed dividendContract, uint256 shares);
    event Unwrapped(address indexed to, uint256 shares, uint256[] amounts);

    error UnsupportedAsset();
    error TaxTokenAlreadySet();
    error TaxTokenNotSet();
    error NoDividendContract();
    error StaleOrInvalidPrice(address asset);
    error NothingToProcess();
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

    function initialize(
        address[] calldata subset_,
        bytes4[] calldata feedIds_,
        address oracle_,
        address owner_
    ) external initializer {
        require(subset_.length > 0 && subset_.length == feedIds_.length, "bad subset");
        require(oracle_ != address(0) && oracle_.code.length > 0, "bad oracle");
        __Ownable_init(owner_);
        __ERC20_init("Index Basket Asian Stock Strategy", "IB-ASS");
        oracle = IPriceHub(oracle_);
        oracleDecimals = IPriceHub(oracle_).decimals(); // read, never assume
        for (uint256 i; i < subset_.length; ++i) {
            require(subset_[i] != address(0) && subset_[i].code.length > 0, "bad asset");
            require(feedIds_[i] != bytes4(0), "bad feed id");
            _subset.push(subset_[i]);
            isSupportedAsset[subset_[i]] = true;
            feedIdOf[subset_[i]] = feedIds_[i];
            emit FeedSet(subset_[i], feedIds_[i]);
        }
        maxFeedAge = 6 hours; // proxy-safe default; tunable once staging shows real aggregation cadence
    }

    // ---------------------------------------------------------------- admin
    /// @notice one-time launch coupling: the tax token whose dividend contract
    /// this basket serves (dividendContract() is re-read live on every claim).
    function setTaxToken(address t) external onlyOwnerOrGuardian {
        if (taxToken != address(0)) revert TaxTokenAlreadySet();
        require(t != address(0) && t.code.length > 0, "bad token");
        taxToken = t;
        emit TaxTokenSet(t);
    }

    function setFeedId(address asset, bytes4 feedId) external onlyOwnerOrGuardian {
        if (!isSupportedAsset[asset]) revert UnsupportedAsset();
        require(feedId != bytes4(0), "bad feed id");
        feedIdOf[asset] = feedId;
        emit FeedSet(asset, feedId);
    }

    function setMaxFeedAge(uint256 age) external onlyOwnerOrGuardian {
        require(age >= 5 minutes, "too tight");
        maxFeedAge = age;
        emit MaxFeedAgeSet(age);
    }

    // ---------------------------------------------------------------- views (tutorial surface)
    function getSubset() external view returns (address[] memory) { return _subset; }

    function pooledAmount(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice USD value (1e18) of `amount` raw units of `asset` at the LIVE
    /// Atlas price. Staleness bound on aggregatedTs — the off-chain data age,
    /// not merely when it was last pushed. BEP-677: raw -> display via the
    /// asset's multiplier before pricing.
    function assetValueUsd(address asset, uint256 amount) public view returns (uint256) {
        if (!isSupportedAsset[asset]) revert UnsupportedAsset();
        IPriceHub.PriceSnapshot memory s = oracle.fetch(feedIdOf[asset]);
        if (s.price == 0 || uint256(s.aggregatedTs) + maxFeedAge < block.timestamp) {
            revert StaleOrInvalidPrice(asset);
        }
        uint256 display = _displayAmount(asset, amount);
        return Math.mulDiv(display, uint256(s.price), 10 ** oracleDecimals);
    }

    /// @notice live oracle-priced NAV across all pooled components (1e18 USD).
    function totalNavUsd() public view returns (uint256 nav) {
        uint256 len = _subset.length;
        for (uint256 i; i < len; ++i) {
            uint256 pooled = pooledAmount(_subset[i]);
            if (pooled != 0) nav += assetValueUsd(_subset[i], pooled);
        }
    }

    function previewMint(address asset, uint256 amount) public view returns (uint256 shares) {
        uint256 depositValue = assetValueUsd(asset, amount);
        uint256 supplyBefore = totalSupply();
        if (supplyBefore == 0) {
            shares = depositValue > MINIMUM_LIQUIDITY ? depositValue - MINIMUM_LIQUIDITY : 0;
        } else {
            uint256 navBefore = totalNavUsd() - _unprocessedValueUsd(); // exclude the deposit itself
            shares = navBefore == 0 ? 0 : Math.mulDiv(depositValue, supplyBefore, navBefore);
        }
    }

    // ---------------------------------------------------------------- processing
    /// @notice PERMISSIONLESS: mint shares against every component's unprocessed
    /// balance-delta (engine buys deliver bStocks here), then deposit ALL basket
    /// shares held into the tax token's dividend contract. Anyone may call;
    /// the TriggerAdapter pokes it each cycle.
    function processReceived() external nonReentrant returns (uint256 sharesMinted) {
        if (taxToken == address(0)) revert TaxTokenNotSet();
        address div = IFlapTaxTokenDividendSource(taxToken).dividendContract();
        if (div == address(0)) revert NoDividendContract();

        uint256 supplyBefore = totalSupply();
        uint256 navBefore = totalNavUsd() - _unprocessedValueUsd(); // value of the ALREADY-processed pool

        uint256 len = _subset.length;
        for (uint256 i; i < len; ++i) {
            address asset = _subset[i];
            uint256 bal = IERC20(asset).balanceOf(address(this));
            uint256 delta = bal - accounted[asset];
            if (delta == 0) continue;
            uint256 depositValue = assetValueUsd(asset, delta);
            uint256 shares;
            if (supplyBefore == 0) {
                require(depositValue > MINIMUM_LIQUIDITY, "seed too small");
                _mint(DEAD, MINIMUM_LIQUIDITY);            // tutorial: lock the ratio forever
                shares = depositValue - MINIMUM_LIQUIDITY;
                supplyBefore = MINIMUM_LIQUIDITY;
                navBefore = 0;
            } else {
                shares = navBefore == 0 ? 0 : Math.mulDiv(depositValue, supplyBefore, navBefore);
            }
            if (shares == 0) { accounted[asset] = bal; continue; } // dust: absorbed into NAV (enriches holders)
            _mint(address(this), shares);
            supplyBefore += shares;
            navBefore += depositValue;                     // processed pool grew by exactly this value
            accounted[asset] = bal;
            sharesMinted += shares;
            emit Minted(asset, delta, shares, depositValue);
        }
        if (sharesMinted == 0) revert NothingToProcess();

        // deposit everything we hold into the dividend contract (approve+pull
        // shape; semantics confirmed empirically in the mainnet-fork suite
        // against the live Flap Dividend of the staging token)
        uint256 toDeposit = balanceOf(address(this));
        _approve(address(this), div, toDeposit);
        require(IFlapDividendDeposit(div).deposit(toDeposit), "deposit failed");
        emit DepositedToDividend(div, toDeposit);
    }

    // ---------------------------------------------------------------- auto-unwrap (tutorial section 3)
    /// @dev OZ v5 ERC20 routes all transfers through _update — the tutorial's
    /// _transfer override maps here. A transfer FROM the dividend contract is a
    /// claim payout: unwrap instead of moving basket balance.
    function _update(address from, address to, uint256 value) internal override {
        if (!_unwrapping && value != 0 && from != address(0) && to != address(0) && taxToken != address(0)) {
            address div = IFlapTaxTokenDividendSource(taxToken).dividendContract();
            if (div != address(0) && from == div) {
                _unwrapFrom(from, to, value);
                return;
            }
        }
        super._update(from, to, value);
    }

    /// @dev burns `shares` from the dividend contract and releases each pooled
    /// component pro-rata to the claimer. Atomic: a restricted-transfer
    /// component reverts the whole claim (entitlement remains; user retries).
    function _unwrapFrom(address from, address to, uint256 shares) internal {
        _unwrapping = true;
        uint256 supplyBefore = totalSupply();
        uint256 len = _subset.length;
        uint256[] memory amounts = new uint256[](len);
        _burn(from, shares); // reverts if the dividend contract lacks the balance
        for (uint256 i; i < len; ++i) {
            address asset = _subset[i];
            uint256 pooled = IERC20(asset).balanceOf(address(this));
            uint256 amt = Math.mulDiv(pooled, shares, supplyBefore);
            if (amt != 0) {
                IERC20(asset).safeTransfer(to, amt);
                // keep the processed baseline honest as assets leave the pool
                uint256 acc = accounted[asset];
                accounted[asset] = acc > amt ? acc - amt : 0;
            }
            amounts[i] = amt;
        }
        _unwrapping = false;
        emit Unwrapped(to, shares, amounts);
    }

    // ---------------------------------------------------------------- internal
    function _unprocessedValueUsd() internal view returns (uint256 v) {
        uint256 len = _subset.length;
        for (uint256 i; i < len; ++i) {
            address asset = _subset[i];
            uint256 delta = IERC20(asset).balanceOf(address(this)) - accounted[asset];
            if (delta != 0) v += assetValueUsd(asset, delta);
        }
    }

    /// @dev BEP-677 raw -> display scaling; assets without multiplier() are 1:1.
    function _displayAmount(address asset, uint256 amount) internal view returns (uint256) {
        try IBStockMultiplier(asset).multiplier() returns (uint256 m) {
            return m == 0 ? amount : Math.mulDiv(amount, m, 1e18);
        } catch {
            return amount;
        }
    }
}