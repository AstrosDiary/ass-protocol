// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockBStock is ERC20 {
    uint256 public multiplier = 1e18;          // BEP-677 scaled-UI multiplier
    mapping(address => bool) public restricted; // reverts on transfer TO these
    mapping(address => bool) public softFail;   // returns false instead (non-reverter)
    bool public paused;                         // corporate-action processing window

    constructor() ERC20("Mock bStock", "MBS") {}

    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function setMultiplier(uint256 m) external { multiplier = m; } // corporate action
    function setRestricted(address a, bool on) external { restricted[a] = on; }
    function setSoftFail(address a, bool on) external { softFail[a] = on; }
    function setPaused(bool p) external { paused = p; }

    /// @dev BEP-677: UI amount = raw * multiplier; raw is untouched by design
    function scaledBalanceOf(address a) external view returns (uint256) {
        return balanceOf(a) * multiplier / 1e18;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        require(!paused, "corporate action in progress");
        require(!restricted[to], "recipient restricted");
        if (softFail[to]) return false;
        return super.transfer(to, amt);
    }
}