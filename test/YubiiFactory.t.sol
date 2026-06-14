// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

import {YubiiToken} from "../src/YubiiToken.sol";
import {YubiiFactory} from "../src/YubiiFactory.sol";
import {MatchMarket} from "../src/MatchMarket.sol";
import {MockOptimisticOracleV3} from "./mocks/MockOptimisticOracleV3.sol";

contract YubiiFactoryTest is Test {
    PoolManager pm;
    YubiiToken yubii;
    MockOptimisticOracleV3 oracle;
    YubiiFactory factory;

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");

    function setUp() public {
        pm = new PoolManager(owner);
        yubii = new YubiiToken(owner);
        oracle = new MockOptimisticOracleV3();

        factory = new YubiiFactory(
            address(pm),
            address(yubii),
            address(oracle),
            feeRecipient,
            owner,
            owner // marketingWallet
        );
        vm.deal(owner, 10 ether);
    }

    function test_createMatch_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit YubiiFactory.MatchCreated(
            address(0),
            "Arsenal",
            "Chelsea",
            block.timestamp + 1 days,
            0.1 ether,
            0,
            1 // BALANCED
        );

        vm.prank(owner);
        factory.createMatch{value: 0.1 ether}("Arsenal", "Chelsea", block.timestamp + 1 days, 1);
    }

    function test_createMatch_storesMarket() public {
        vm.prank(owner);
        address market = factory.createMatch{value: 0.1 ether}("Arsenal", "Chelsea", block.timestamp + 1 days, 1);

        assertEq(factory.marketCount(), 1);
        assertEq(factory.markets(0), market);
    }

    function test_createMatch_marketHasCorrectState() public {
        uint256 kickoff = block.timestamp + 2 days;
        vm.prank(owner);
        address marketAddr = factory.createMatch{value: 0.2 ether}("Real Madrid", "Barcelona", kickoff, 1);

        MatchMarket m = MatchMarket(payable(marketAddr));
        assertEq(m.teamA(), "Real Madrid");
        assertEq(m.teamB(), "Barcelona");
        assertEq(m.kickoffTime(), kickoff);
        assertFalse(m.settled());
        assertGt(m.liquidityA(), 0);
    }

    function test_createMultipleMatches() public {
        vm.startPrank(owner);
        factory.createMatch{value: 0.1 ether}("Team1", "Team2", block.timestamp + 1 days, 1);
        factory.createMatch{value: 0.1 ether}("Team3", "Team4", block.timestamp + 2 days, 1);
        factory.createMatch{value: 0.1 ether}("Team5", "Team6", block.timestamp + 3 days, 1);
        vm.stopPrank();

        assertEq(factory.marketCount(), 3);
    }

    function test_createMatch_revertsNonOwner() public {
        vm.deal(alice, 1 ether);
        vm.expectRevert();
        vm.prank(alice);
        factory.createMatch{value: 0.1 ether}("Arsenal", "Chelsea", block.timestamp + 1 days, 1);
    }

    function test_createMatch_revertsNoLiquidity() public {
        vm.expectRevert(YubiiFactory.NoInitialLiquidity.selector);
        vm.prank(owner);
        factory.createMatch{value: 0}("Arsenal", "Chelsea", block.timestamp + 1 days, 1);
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        factory.setFeeRecipient(newRecipient);
        assertEq(factory.feeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_revertsNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        factory.setFeeRecipient(alice);
    }

    // ─────────────────────── freeze / thaw ───────────────────────────────────

    function test_freezeLeague_holdsAllMarkets() public {
        vm.startPrank(owner);
        address m1 = factory.createMatch{value: 0.1 ether}("USA", "MEX", block.timestamp + 1 days, 1);
        address m2 = factory.createMatch{value: 0.1 ether}("ENG", "FRA", block.timestamp + 2 days, 1);
        factory.freezeLeague();
        vm.stopPrank();
        assertTrue(MatchMarket(payable(m1)).held());
        assertTrue(MatchMarket(payable(m2)).held());
    }

    function test_thawLeague_resumesAllMarkets() public {
        vm.startPrank(owner);
        address m1 = factory.createMatch{value: 0.1 ether}("USA", "MEX", block.timestamp + 1 days, 1);
        factory.freezeLeague();
        factory.thawLeague();
        vm.stopPrank();
        assertFalse(MatchMarket(payable(m1)).held());
    }

    function test_freezeLeague_revertsNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        factory.freezeLeague();
    }
}
