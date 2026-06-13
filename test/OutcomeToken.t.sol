// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

contract OutcomeTokenTest is Test {
    OutcomeToken token;
    address market = makeAddr("market");
    address alice = makeAddr("alice");

    function setUp() public {
        token = new OutcomeToken("Manchester United", "MAN", market);
    }

    function test_name() public view {
        assertEq(token.name(), "YUBII: Manchester United");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "yMAN");
    }

    function test_market() public view {
        assertEq(token.market(), market);
    }

    function test_mint() public {
        vm.prank(market);
        token.mint(alice, 1000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.totalSupply(), 1000 ether);
    }

    function test_burn() public {
        vm.prank(market);
        token.mint(alice, 1000 ether);
        vm.prank(market);
        token.burn(alice, 400 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    function test_revertMintOnlyMarket() public {
        vm.expectRevert(OutcomeToken.OnlyMarket.selector);
        token.mint(alice, 1000 ether);
    }

    function test_revertBurnOnlyMarket() public {
        vm.prank(market);
        token.mint(alice, 100 ether);
        vm.expectRevert(OutcomeToken.OnlyMarket.selector);
        token.burn(alice, 100 ether);
    }

    function test_fuzz_mintBurn(uint256 mintAmt, uint256 burnAmt) public {
        mintAmt = bound(mintAmt, 1, type(uint128).max);
        burnAmt = bound(burnAmt, 0, mintAmt);

        vm.startPrank(market);
        token.mint(alice, mintAmt);
        token.burn(alice, burnAmt);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), mintAmt - burnAmt);
    }
}
