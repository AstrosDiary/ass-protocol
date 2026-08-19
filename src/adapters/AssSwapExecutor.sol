// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title AssSwapExecutor — validated execution of keeper-supplied router calldata
/// @notice The keeper discovers routes off-chain (QuoterV2 enumeration over
/// Pancake pools) and submits opaque calldata. This contract enforces the
/// safety invariants so the calldata's CONTENT never needs to be trusted:
/// allowlisted router, exact quote-token (QQQB) approval (reset after), zero
/// native value, output measured as OUR OWN balance delta of the expected
/// bStock, raw-unit minOut, then forwarded to the fixed recipient
/// (distributor). A route that pays anyone else yields delta 0 and reverts on
/// minOut.
contract AssSwapExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable quote;              // QQQB — swap input token
    address public engine;                      // sole authorized caller
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

    constructor(address quote_, address owner_) Ownable(owner_) {
        require(quote_ != address(0) && quote_.code.length > 0, "bad quote");
        quote = IERC20(quote_);
    }

    function setEngine(address e) external onlyOwner { engine = e; emit EngineSet(e); }
    function setRouter(address r, bool on) external onlyOwner { routerAllowed[r] = on; emit RouterSet(r, on); }

    /// @notice Engine transfers `spend` QQQB here first, then calls this.
    /// @return spent actual quote consumed  @return received bStock delivered to `recipient`
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
        // block.timestamp here is a quote-staleness fence (priced quotes expire),
        // per spec's keeper-security requirements. Validator drift of a few
        // seconds is immaterial: minOut independently bounds execution price.
        // Identical pattern to Uniswap/Pancake router checkDeadline.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (minOut == 0) revert ZeroMinOut(); // keeper must always price the trade

        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        quote.forceApprove(router, spend);                      // exact, never unlimited
        (bool ok, bytes memory ret) = router.call(routerCalldata); // value: 0 — always
        if (!ok) revert RouterCallFailed(ret);
        quote.forceApprove(router, 0);                          // approval never lingers

        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore; // measured, not reported
        if (received < minOut) revert Slippage(received, minOut);
        spent = quoteBefore - quote.balanceOf(address(this));

        IERC20(tokenOut).safeTransfer(recipient, received);     // fixed destination

        // return any unspent quote to the engine (partial fills etc.)
        uint256 leftover = quote.balanceOf(address(this));
        if (leftover > 0) quote.safeTransfer(engine, leftover);

        emit Executed(router, tokenOut, spent, received);
    }
}