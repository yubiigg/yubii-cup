// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {YubiiToken} from "../src/YubiiToken.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MatchMarket} from "../src/MatchMarket.sol";
import {MockOptimisticOracleV3} from "./mocks/MockOptimisticOracleV3.sol";

contract MatchMarketTest is Test {
    PoolManager pm;
    YubiiToken yubii;
    MockOptimisticOracleV3 oracle;
    MatchMarket market;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeRecipient = makeAddr("feeRecipient");

    uint256 constant INITIAL_LIQUIDITY = 0.2 ether;
    uint256 constant KICKOFF = 2 days;

    function setUp() public {
        pm = new PoolManager(owner);
        yubii = new YubiiToken(owner);
        oracle = new MockOptimisticOracleV3();

        // Give alice and bob SHOBU for fees
        vm.prank(owner);
        yubii.transfer(alice, 1_000_000 ether);
        vm.prank(owner);
        yubii.transfer(bob, 1_000_000 ether);

        // Create market with initial liquidity (two-phase: deploy then init)
        market = new MatchMarket{value: INITIAL_LIQUIDITY}(
            address(pm),
            address(yubii),
            feeRecipient,
            address(oracle),
            "Manchester United",
            "Liverpool",
            block.timestamp + KICKOFF,
            owner
        );
        market.initializeLiquidity();

        // Approve market to spend SHOBU
        vm.prank(alice);
        yubii.approve(address(market), type(uint256).max);
        vm.prank(bob);
        yubii.approve(address(market), type(uint256).max);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ─────────────────────── deployment ─────────────────────────────────────

    function test_initialState() public view {
        assertEq(market.teamA(), "Manchester United");
        assertEq(market.teamB(), "Liverpool");
        assertFalse(market.settled());
        assertEq(market.winner(), 0);
        assertEq(market.totalSettledETH(), 0);
        assertGt(market.liquidityA(), 0);
        assertGt(market.liquidityB(), 0);
    }

    function test_tokenNames() public view {
        OutcomeToken tA = market.tokenA();
        OutcomeToken tB = market.tokenB();
        assertEq(tA.name(), "YUBII: Manchester United");
        assertEq(tB.name(), "YUBII: Liverpool");
        assertEq(tA.symbol(), "yMANC");
        assertEq(tB.symbol(), "yLIVE");
    }

    function test_poolsInitialized() public view {
        // Both pools have equal initial liquidity
        assertEq(market.liquidityA(), market.liquidityB());
    }

    // ─────────────────────── buy ─────────────────────────────────────────────

    function test_buyTeamA() public {
        uint256 ethIn = 0.01 ether;
        uint256 yubiiBefore = yubii.balanceOf(alice);
        uint256 feeRecipientBefore = yubii.balanceOf(feeRecipient);

        vm.prank(alice);
        market.buy{value: ethIn}(true, 0);

        OutcomeToken tA = market.tokenA();
        uint256 tokensReceived = tA.balanceOf(alice);
        assertGt(tokensReceived, 0);

        // SHOBU fee collected
        uint256 expectedFee = (ethIn * 30) / 10000;
        assertEq(yubii.balanceOf(alice), yubiiBefore - expectedFee);
        assertEq(yubii.balanceOf(feeRecipient), feeRecipientBefore + expectedFee);
    }

    function test_buyTeamB() public {
        uint256 ethIn = 0.01 ether;

        vm.prank(bob);
        market.buy{value: ethIn}(false, 0);

        OutcomeToken tB = market.tokenB();
        assertGt(tB.balanceOf(bob), 0);
    }

    function test_buyReverts_ifSettled() public {
        _settleTeamA();
        vm.expectRevert(MatchMarket.MarketSettled.selector);
        vm.prank(alice);
        market.buy{value: 0.01 ether}(true, 0);
    }

    function test_buyReverts_zeroValue() public {
        vm.expectRevert(MatchMarket.ZeroAmount.selector);
        vm.prank(alice);
        market.buy{value: 0}(true, 0);
    }

    function test_buyReverts_slippage() public {
        uint256 ethIn = 0.001 ether;
        uint256 impossibleMin = 10_000 ether;
        vm.expectRevert(MatchMarket.SlippageExceeded.selector);
        vm.prank(alice);
        market.buy{value: ethIn}(true, impossibleMin);
    }

    // ─────────────────────── sell ─────────────────────────────────────────────

    function test_sell() public {
        // First buy some tokens
        vm.prank(alice);
        market.buy{value: 0.05 ether}(true, 0);

        OutcomeToken tA = market.tokenA();
        uint256 tokenBal = tA.balanceOf(alice);
        assertGt(tokenBal, 0);

        uint256 ethBefore = alice.balance;
        uint256 yubiiBefore = yubii.balanceOf(alice);

        // Approve market to pull tokens
        vm.prank(alice);
        tA.approve(address(market), tokenBal);

        uint256 sellAmt = tokenBal / 2;
        vm.prank(alice);
        market.sell(true, sellAmt, 0);

        assertGt(alice.balance, ethBefore); // received ETH
        // SHOBU fee on sell
        uint256 expectedFee = (sellAmt * 30) / 10000;
        assertEq(yubii.balanceOf(alice), yubiiBefore - expectedFee);
    }

    function test_sellReverts_ifSettled() public {
        vm.prank(alice);
        market.buy{value: 0.01 ether}(true, 0);
        OutcomeToken tA = market.tokenA();
        uint256 amt = tA.balanceOf(alice);

        _settleTeamA();

        vm.prank(alice);
        tA.approve(address(market), amt);
        vm.expectRevert(MatchMarket.MarketSettled.selector);
        vm.prank(alice);
        market.sell(true, amt, 0);
    }

    function test_sellReverts_zeroAmount() public {
        vm.expectRevert(MatchMarket.ZeroAmount.selector);
        vm.prank(alice);
        market.sell(true, 0, 0);
    }

    // ─────────────────────── settlement ──────────────────────────────────────

    function test_requestSettlement() public {
        vm.warp(block.timestamp + KICKOFF + 1);
        bytes32 assertionId = market.requestSettlement(1, address(this), address(0), 0);
        assertNotEq(assertionId, bytes32(0));
        assertEq(market.pendingAssertionId(), assertionId);
        assertEq(market.pendingWinner(), 1);
    }

    function test_settlement_teamAWins() public {
        // Alice buys teamA, bob buys teamB
        vm.prank(alice);
        market.buy{value: 0.05 ether}(true, 0);
        vm.prank(bob);
        market.buy{value: 0.05 ether}(false, 0);

        _settleTeamA();

        assertTrue(market.settled());
        assertEq(market.winner(), 1);
        assertGt(market.totalSettledETH(), 0);
    }

    function test_settlement_teamBWins() public {
        vm.prank(alice);
        market.buy{value: 0.05 ether}(true, 0);
        vm.prank(bob);
        market.buy{value: 0.05 ether}(false, 0);

        _settleTeamB();

        assertTrue(market.settled());
        assertEq(market.winner(), 2);
        assertGt(market.totalSettledETH(), 0);
    }

    function test_requestSettlement_revertsTooEarly() public {
        vm.expectRevert(MatchMarket.TooEarly.selector);
        market.requestSettlement(1, address(this), address(0), 0);
    }

    function test_requestSettlement_revertsIfPending() public {
        vm.warp(block.timestamp + KICKOFF + 1);
        market.requestSettlement(1, address(this), address(0), 0);
        vm.expectRevert(MatchMarket.AssertionPending.selector);
        market.requestSettlement(1, address(this), address(0), 0);
    }

    function test_requestSettlement_revertsIfSettled() public {
        _settleTeamA();
        vm.expectRevert(MatchMarket.MarketSettled.selector);
        market.requestSettlement(1, address(this), address(0), 0);
    }

    function test_disputeResetsAssertion() public {
        vm.warp(block.timestamp + KICKOFF + 1);
        bytes32 assertionId = market.requestSettlement(1, address(this), address(0), 0);
        oracle.mockDispute(assertionId);

        assertEq(market.pendingAssertionId(), bytes32(0));
        assertEq(market.pendingWinner(), 0);
        assertFalse(market.settled());

        // Can re-request
        market.requestSettlement(2, address(this), address(0), 0);
        assertNotEq(market.pendingAssertionId(), bytes32(0));
    }

    function test_falseAssertionDoesNotSettle() public {
        vm.warp(block.timestamp + KICKOFF + 1);
        bytes32 assertionId = market.requestSettlement(1, address(this), address(0), 0);
        oracle.mockResolve(assertionId, false);
        assertFalse(market.settled());
    }

    // ─────────────────────── redemption ──────────────────────────────────────

    function test_redeem_winnerGetsETH() public {
        vm.prank(alice);
        market.buy{value: 0.05 ether}(true, 0);
        vm.prank(bob);
        market.buy{value: 0.05 ether}(false, 0);

        _settleTeamA();

        OutcomeToken tA = market.tokenA();
        uint256 aliceTokens = tA.balanceOf(alice);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        tA.approve(address(market), aliceTokens);
        vm.prank(alice);
        market.redeem(aliceTokens);

        assertGt(alice.balance, ethBefore);
        assertEq(tA.balanceOf(alice), 0);
    }

    function test_redeem_proportionalShare() public {
        // Alice and Bob both buy TeamA — verify proportional redemption
        vm.prank(alice);
        market.buy{value: 0.04 ether}(true, 0);
        vm.prank(bob);
        market.buy{value: 0.04 ether}(true, 0);

        _settleTeamA();

        OutcomeToken tA = market.tokenA();
        uint256 totalSettled = market.totalSettledETH();
        uint256 totalSupply = tA.totalSupply();

        uint256 aliceTokens = tA.balanceOf(alice);
        uint256 bobTokens = tA.balanceOf(bob);

        uint256 aliceExpected = (aliceTokens * totalSettled) / totalSupply;
        uint256 bobExpected = (bobTokens * totalSettled) / totalSupply;

        vm.prank(alice);
        tA.approve(address(market), aliceTokens);
        vm.prank(alice);
        market.redeem(aliceTokens);

        vm.prank(bob);
        tA.approve(address(market), bobTokens);
        vm.prank(bob);
        market.redeem(bobTokens);

        // Both get their proportional share (within 1 wei rounding)
        assertApproxEqAbs(alice.balance, aliceExpected + (10 ether - 0.04 ether), 1e9);
        assertApproxEqAbs(bob.balance, bobExpected + (10 ether - 0.04 ether), 1e9);
    }

    function test_redeem_revertsIfNotSettled() public {
        vm.expectRevert(MatchMarket.MarketNotSettled.selector);
        vm.prank(alice);
        market.redeem(100 ether);
    }

    function test_redeem_revertsZeroAmount() public {
        _settleTeamA();
        vm.expectRevert(MatchMarket.ZeroAmount.selector);
        vm.prank(alice);
        market.redeem(0);
    }

    // ─────────────────────── helpers ─────────────────────────────────────────

    function _settleTeamA() internal {
        vm.warp(block.timestamp + KICKOFF + 1);
        bytes32 assertionId = market.requestSettlement(1, address(this), address(0), 0);
        oracle.mockResolve(assertionId, true);
    }

    function _settleTeamB() internal {
        vm.warp(block.timestamp + KICKOFF + 1);
        bytes32 assertionId = market.requestSettlement(2, address(this), address(0), 0);
        oracle.mockResolve(assertionId, true);
    }
}
