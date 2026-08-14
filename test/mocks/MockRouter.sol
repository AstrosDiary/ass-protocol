// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {MockBStock} from "./MockBStock.sol";

contract MockRouter {
    enum Mode { Honest, Revert, UnderDeliver, WrongRecipient, PartialSpend }
    Mode public mode;
    uint256 public rate = 100e18; // tokenOut per 1e18 WBNB
    address public thief = address(0xBAD);

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