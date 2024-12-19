// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockYoko is ERC20 {
    constructor() ERC20("Mock YOKO", "YOKO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
