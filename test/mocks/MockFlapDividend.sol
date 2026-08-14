// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockFlapDividend {
    mapping(address => uint256) public share;
    mapping(address => bool) public excludedFromDividends;
    uint256 public totalShares;
    uint256 public minimumShareBalance = 10_000e18;

    function setShare(address u, uint256 s) external {
        totalShares = totalShares - share[u] + s;
        share[u] = s;
    }
    function setExcluded(address u, bool on) external { excludedFromDividends[u] = on; }

    function userInfo(address u) external view returns (uint256, uint256, uint256) {
        if (excludedFromDividends[u]) return (0, 0, 0);
        return (share[u], 0, 0);
    }
}