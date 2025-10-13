// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.20;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Asset is ERC20("Asset Token", "ASSET") {

    constructor() {
        // total supply 1 million tokens
        _mint(address(this), 1_000_000 ether);
    }

    function getAsset() external returns (bool) {
        _transfer(address(this), msg.sender, 100 ether);
        return true;
    }
}