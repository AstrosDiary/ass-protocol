// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockBStock} from "./MockBStock.sol";

contract MockRouter {
    enum Mode { Honest, Revert, UnderDeliver, WrongRecipient, PartialSpend }
    Mode public mode;
    uint256 public rate = 100e18; // tokenOut per 1e18 WBNB
    address public thief = address(0xBAD);

    // Adapter compatibility: the TriggerAdapter calls multicall(deadline, [exactInput(...)]).
    // Decode just enough to service it: pull the allowance of `pairIn` from the
    // caller, mint `pairOut` at `rate` to the caller. Configure per-test for
    // whichever leg (bStock buy or gas top-up) the test exercises.
    address public pairIn; address public pairOut;
    function setPair(address in_, address out_) external { pairIn = in_; pairOut = out_; }

    fallback(bytes calldata) external returns (bytes memory) {
        require(mode != Mode.Revert, "router: no route");
        uint256 amountIn = IERC20(pairIn).allowance(msg.sender, address(this));
        IERC20(pairIn).transferFrom(msg.sender, address(this), amountIn);
        MockBStock(pairOut).mint(msg.sender, amountIn * rate / 1e18);
        return "";
    }

    function setMode(Mode m) external { mode = m; }
    function setRate(uint256 r) external { rate = r; }

    function swap(address wbnb, address tokenOut, uint256 amountIn) external {
        if (mode == Mode.Revert) revert("router: no route");
        uint256 pull = mode == Mode.PartialSpend ? amountIn / 2 : amountIn;
        IERC20(wbnb).transferFrom(msg.sender, address(this), pull);
        uint256 out = pull * rate / 1e18;
        if (mode == Mode.UnderDeliver) out = out / 10;
        address to = mode == Mode.WrongRecipient ? thief : msg.sender;
        MockBStock(tokenOut).mint(to, out);
    }
}