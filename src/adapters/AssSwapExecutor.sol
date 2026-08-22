// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AssSwapExecutor — validated execution of keeper-supplied router calldata
/// @notice (invariants unchanged — see prior NatSpec) Beacon-upgradeable per
/// Flap satellite doctrine: Guardian owns the beacon and is a parallel
/// emergency caller on every sensitive function (onlyOwnerOrGuardian).
contract AssSwapExecutor is Initializable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public quote;                        // QQQB (storage — proxy pattern)
    address public engine;
    mapping(address => bool) public routerAllowed;

    event RouterSet(address indexed router, bool allowed);
    event EngineSet(address indexed engine);
    event Executed(address indexed router, address indexed tokenOut, uint256 quoteSpent, uint256 received);

    error OnlyEngine();
    error RouterNotAllowed();
    error DeadlinePassed();
    error ZeroMinOut();
    error Slippage(uint256 got, uint256 minOut);
    error RouterCallFailed(bytes reason);
    error Unauthorized();
    error UnsupportedChain(uint256 chainId);

    // ---- Flap guardian mandate (satellite form) ----
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

    function initialize(address quote_, address owner_) external initializer {
        require(quote_ != address(0) && quote_.code.length > 0, "bad quote");
        __Ownable_init(owner_);
        quote = IERC20(quote_);
    }

    function setEngine(address e) external onlyOwnerOrGuardian { engine = e; emit EngineSet(e); }
    function setRouter(address r, bool on) external onlyOwnerOrGuardian { routerAllowed[r] = on; emit RouterSet(r, on); }

    function execute(
        address router,
        bytes calldata routerCalldata,
        uint256 spend,
        address tokenOut,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 spent, uint256 received) {
        if (msg.sender != engine) revert OnlyEngine();
        if (!routerAllowed[router]) revert RouterNotAllowed();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (minOut == 0) revert ZeroMinOut();

        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        quote.forceApprove(router, spend);
        (bool ok, bytes memory ret) = router.call(routerCalldata);
        if (!ok) revert RouterCallFailed(ret);
        quote.forceApprove(router, 0);

        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (received < minOut) revert Slippage(received, minOut);
        spent = quoteBefore - quote.balanceOf(address(this));

        IERC20(tokenOut).safeTransfer(recipient, received);

        uint256 leftover = quote.balanceOf(address(this));
        if (leftover > 0) quote.safeTransfer(engine, leftover);

        emit Executed(router, tokenOut, spent, received);
    }
}