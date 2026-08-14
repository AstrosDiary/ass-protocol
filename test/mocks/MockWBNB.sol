// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amt) external {
        _burn(msg.sender, amt);
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "send fail");
    }
    receive() external payable {}
}