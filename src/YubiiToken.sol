// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract YubiiToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor(address owner) ERC20("Yubii", "YUBII") Ownable(owner) {
        _mint(owner, TOTAL_SUPPLY);
    }
}
