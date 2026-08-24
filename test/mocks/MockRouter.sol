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
    // Two service levels:
    //  - permissive (default): pull pairIn by allowance, mint pairOut to caller —
    //    calldata ignored. Kept for legs where encoding isn't under test.
    //  - strictDecode: actually decode multicall + the exactInput STRUCT the way
    //    the real SmartRouter does. Regression guard for the flat-args encoding
    //    bug (incident: 12x RouterCallFailed(empty), 2026-08-22).
    address public pairIn; address public pairOut;
    bool public strictDecode;
    function setPair(address in_, address out_) external { pairIn = in_; pairOut = out_; }
    function setStrictDecode(bool s) external { strictDecode = s; }

    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }

    fallback(bytes calldata cd) external returns (bytes memory) {
        require(mode != Mode.Revert, "router: no route");
        if (strictDecode) {
            require(bytes4(cd[:4]) == bytes4(0x5ae401dc), "not multicall");
            (, bytes[] memory calls) = abi.decode(cd[4:], (uint256, bytes[]));
            require(bytes4(calls[0]) == bytes4(0xb858183f), "not exactInput");
            ExactInputParams memory p = abi.decode(_stripSelector(calls[0]), (ExactInputParams));
            IERC20(pairIn).transferFrom(msg.sender, address(this), p.amountIn);
            MockBStock(pairOut).mint(p.recipient, p.amountIn * rate / 1e18);
            return "";
        }
        uint256 amountIn = IERC20(pairIn).allowance(msg.sender, address(this));
        IERC20(pairIn).transferFrom(msg.sender, address(this), amountIn);
        MockBStock(pairOut).mint(msg.sender, amountIn * rate / 1e18);
        return "";
    }

    function _stripSelector(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = b[i + 4];
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