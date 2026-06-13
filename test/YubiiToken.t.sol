// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YubiiToken} from "../src/YubiiToken.sol";

contract YubiiTokenTest is Test {
    YubiiToken token;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        token = new YubiiToken(owner);
    }

    function test_name() public view {
        assertEq(token.name(), "Yubii");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "YUBII");
    }

    function test_totalSupply() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
    }

    function test_ownerReceivesAllSupply() public view {
        assertEq(token.balanceOf(owner), token.totalSupply());
    }

    function test_transfer() public {
        vm.prank(owner);
        token.transfer(alice, 1000 * 1e18);
        assertEq(token.balanceOf(alice), 1000 * 1e18);
    }

    function test_approve_and_transferFrom() public {
        vm.prank(owner);
        token.approve(alice, 500 * 1e18);
        vm.prank(alice);
        token.transferFrom(owner, alice, 500 * 1e18);
        assertEq(token.balanceOf(alice), 500 * 1e18);
    }

    function test_fuzz_transferAmount(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(owner);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(owner), token.totalSupply() - amount);
    }
}
