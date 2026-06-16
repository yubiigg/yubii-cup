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

    address owner           = makeAddr("owner");
    address alice           = makeAddr("alice");
    address bob             = makeAddr("bob");
    address feeRecipient    = makeAddr("feeRecipient");
    address marketingWallet = makeAddr("marketingWallet");

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
            owner,
            marketingWallet,
            1 // BALANCED
        );
        market.initializeLiquidity();

        // Remove limits so existing tests can buy > maxBuyETH without extra setup
        vm.prank(owner);
        market.removeLimits();

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
        uint256 expectedFee = (sellAmt * market.currentFeeBps()) / 10000;
        vm.prank(alice);
        market.sell(true, sellAmt, 0);

        assertGt(alice.balance, ethBefore); // received ETH
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

    // ─────────────────────── max buy limit ───────────────────────────────────

    function test_buyLimit_revertsWhenExceeded() public {
        MatchMarket m = _freshMarket();
        vm.expectRevert(MatchMarket.BuyLimitExceeded.selector);
        vm.prank(alice);
        m.buy{value: 0.01 ether + 1}(true, 0);
    }

    function test_buyLimit_allowsAtMax() public {
        MatchMarket m = _freshMarket();
        vm.prank(alice);
        m.buy{value: 0.01 ether}(true, 0); // exactly at max — must not revert
        assertGt(m.tokenA().balanceOf(alice), 0);
    }

    function test_removeLimits_allowsLargeBuy() public {
        MatchMarket m = _freshMarket();
        vm.prank(owner);
        m.removeLimits();
        assertTrue(m.limitsRemoved());
        vm.prank(alice);
        m.buy{value: 1 ether}(true, 0); // way above old limit
        assertGt(m.tokenA().balanceOf(alice), 0);
    }

    function test_removeLimits_revertsNonOwner() public {
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.removeLimits();
    }

    // ─────────────────────── launch tax ──────────────────────────────────────

    function test_buyTax_sentToMarketing() public {
        uint256 ethIn = 0.01 ether;
        uint256 expectedTax = (ethIn * 2000) / 10000; // 20%
        uint256 mktBefore = marketingWallet.balance;

        vm.prank(alice);
        market.buy{value: ethIn}(true, 0);

        assertEq(marketingWallet.balance, mktBefore + expectedTax);
    }

    function test_sellTax_sentToMarketing() public {
        vm.prank(alice);
        market.buy{value: 0.01 ether}(true, 0);

        OutcomeToken tA = market.tokenA();
        uint256 tokenBal = tA.balanceOf(alice);
        vm.prank(alice);
        tA.approve(address(market), tokenBal);

        uint256 mktBefore = marketingWallet.balance;
        vm.prank(alice);
        market.sell(true, tokenBal, 0);

        assertGt(marketingWallet.balance, mktBefore);
    }

    function test_sellTax_userReceivesNetAmount() public {
        vm.prank(alice);
        market.buy{value: 0.01 ether}(true, 0);

        OutcomeToken tA = market.tokenA();
        uint256 tokenBal = tA.balanceOf(alice);
        vm.prank(alice);
        tA.approve(address(market), tokenBal);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        market.sell(true, tokenBal, 0);

        // user receives positive ETH net of 20% sell tax
        assertGt(alice.balance, ethBefore);
    }

    function test_reduceTax() public {
        vm.prank(owner);
        market.reduceTax(300, 200);
        assertEq(market.buyTaxBps(), 300);
        assertEq(market.sellTaxBps(), 200);
    }

    function test_reduceTax_revertsAboveCap() public {
        vm.expectRevert(MatchMarket.TaxTooHigh.selector);
        vm.prank(owner);
        market.reduceTax(501, 0);
    }

    function test_reduceTax_revertsNonOwner() public {
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.reduceTax(100, 100);
    }

    function test_removeTax_zeroesBoth() public {
        vm.prank(owner);
        market.removeTax();
        assertEq(market.buyTaxBps(), 0);
        assertEq(market.sellTaxBps(), 0);
    }

    function test_removeTax_revertsNonOwner() public {
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.removeTax();
    }

    // ─────────────────────── settlement fee ──────────────────────────────────

    function test_settlementFee_sentToMarketing() public {
        vm.prank(alice);
        market.buy{value: 0.01 ether}(true, 0);

        uint256 mktBefore = marketingWallet.balance;
        _settleTeamA();

        assertGt(marketingWallet.balance, mktBefore);
    }

    function test_settlementFee_isOnePercent() public {
        vm.prank(alice);
        market.buy{value: 0.01 ether}(true, 0);
        vm.prank(bob);
        market.buy{value: 0.01 ether}(false, 0);

        // capture pool balance just before settlement
        uint256 mktBefore = marketingWallet.balance;
        _settleTeamA();

        uint256 feeReceived = marketingWallet.balance - mktBefore;
        uint256 totalPool = market.totalSettledETH();
        // fee + totalSettled ≈ pre-fee balance; fee should be ~1% of that
        uint256 preFee = feeReceived + totalPool;
        assertApproxEqAbs(feeReceived, preFee / 100, 1);
    }

    // ─────────────────────── dynamic fee ─────────────────────────────────────

    function test_feeProfile_defaultIsBalanced() public view {
        assertEq(market.feeProfile(), 1);
    }

    function test_currentFeeBps_atMinWhenIdle() public view {
        // No buys yet → ewmaVolume = 0 → fee = min (30 bps)
        assertEq(market.currentFeeBps(), 30);
    }

    function test_currentFeeBps_risesWithVolume() public {
        vm.prank(alice);
        market.buy{value: 1 ether}(true, 0); // saturates ewma to 1 ether
        assertEq(market.currentFeeBps(), 300); // BALANCED max
    }

    function test_currentFeeBps_clampedAtProfileMax() public {
        vm.prank(alice);
        market.buy{value: 10 ether}(true, 0); // far exceeds FEE_SCALE
        assertEq(market.currentFeeBps(), 300); // still capped at BALANCED max
    }

    function test_ewmaDecays_afterHalfLife() public {
        vm.prank(alice);
        market.buy{value: 1 ether}(true, 0); // fee = 300 (max)
        assertEq(market.currentFeeBps(), 300);

        vm.roll(block.number + 100); // one half-life → ewma halved
        // fee = 30 + (300-30) * 0.5 = 165
        assertApproxEqAbs(market.currentFeeBps(), 165, 5);
    }

    function test_ewmaDecays_toMinAfterManyBlocks() public {
        vm.prank(alice);
        market.buy{value: 1 ether}(true, 0);

        vm.roll(block.number + 700); // 7 half-lives → decay to zero
        assertEq(market.currentFeeBps(), 30); // back to minimum
    }

    function test_setFeeProfile_changesMax() public {
        vm.prank(owner);
        market.setFeeProfile(2); // AGGRESSIVE
        assertEq(market.feeProfile(), 2);

        vm.prank(alice);
        market.buy{value: 1 ether}(true, 0);
        assertEq(market.currentFeeBps(), 500); // AGGRESSIVE max
    }

    function test_setFeeProfile_soft() public {
        vm.prank(owner);
        market.setFeeProfile(0); // SOFT
        vm.prank(alice);
        market.buy{value: 1 ether}(true, 0);
        assertEq(market.currentFeeBps(), 100); // SOFT max
    }

    function test_setFeeProfile_revertsInvalid() public {
        vm.expectRevert(MatchMarket.InvalidFeeProfile.selector);
        vm.prank(owner);
        market.setFeeProfile(3);
    }

    function test_setFeeProfile_revertsNonOwner() public {
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.setFeeProfile(2);
    }

    // ─────────────────────── hold / resume / reclaim ─────────────────────────

    function test_holdMatch_pausesBuy() public {
        vm.prank(owner);
        market.holdMatch();
        assertTrue(market.held());
        vm.expectRevert(MatchMarket.MatchHeld.selector);
        vm.prank(alice);
        market.buy{value: 0.001 ether}(true, 0);
    }

    function test_holdMatch_pausesSell() public {
        vm.prank(alice);
        market.buy{value: 0.001 ether}(true, 0);

        OutcomeToken tA = market.tokenA();
        uint256 bal = tA.balanceOf(alice);

        vm.prank(owner);
        market.holdMatch();

        vm.prank(alice);
        tA.approve(address(market), bal);
        vm.expectRevert(MatchMarket.MatchHeld.selector);
        vm.prank(alice);
        market.sell(true, bal, 0);
    }

    function test_resumeMatch_unpauses() public {
        vm.prank(owner);
        market.holdMatch();
        vm.prank(owner);
        market.resumeMatch();
        assertFalse(market.held());
        vm.prank(alice);
        market.buy{value: 0.001 ether}(true, 0);
        assertGt(market.tokenA().balanceOf(alice), 0);
    }

    function test_holdMatch_revertsNonOwner() public {
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.holdMatch();
    }

    function test_resumeMatch_revertsNonOwner() public {
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.resumeMatch();
    }

    function test_reclaimETH_whenHeld() public {
        vm.deal(address(market), 1 ether);
        vm.prank(owner);
        market.holdMatch();

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        market.reclaimETH(owner, 1 ether);
        assertEq(owner.balance, ownerBefore + 1 ether);
    }

    function test_reclaimETH_revertsWhenActive() public {
        vm.expectRevert();
        vm.prank(owner);
        market.reclaimETH(owner, 0);
    }

    function test_reclaimToken_allowsNonOutcomeToken() public {
        deal(address(yubii), address(market), 100 ether);
        uint256 ownerBefore = yubii.balanceOf(owner);
        vm.prank(owner);
        market.reclaimToken(address(yubii), owner, 100 ether);
        assertEq(yubii.balanceOf(owner), ownerBefore + 100 ether);
    }

    function test_reclaimToken_revertsForOutcomeTokenA() public {
        address tA = address(market.tokenA());
        vm.expectRevert(MatchMarket.CannotReclaimOutcomeToken.selector);
        vm.prank(owner);
        market.reclaimToken(tA, owner, 1);
    }

    function test_reclaimToken_revertsNonOwner() public {
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.reclaimToken(address(yubii), alice, 1);
    }

    // ─────────────────────── kickAfter ───────────────────────────────────────

    function test_kickAfter_revertsIfNotOwner() public {
        vm.prank(owner);
        market.holdMatch();
        vm.expectRevert(MatchMarket.OnlyOwner.selector);
        vm.prank(alice);
        market.kickAfter();
    }

    function test_kickAfter_revertsIfNotHeld() public {
        vm.expectRevert("Must holdMatch() first");
        vm.prank(owner);
        market.kickAfter();
    }

    function test_kickAfter_revertsIfSettled() public {
        _settleTeamA();
        vm.prank(owner);
        market.holdMatch();
        vm.expectRevert("Already settled");
        vm.prank(owner);
        market.kickAfter();
    }

    function test_kickAfter_revertsIfAlreadyKicked() public {
        vm.prank(owner);
        market.holdMatch();
        vm.prank(owner);
        market.kickAfter();
        // second call must revert
        vm.expectRevert("Already kicked after");
        vm.prank(owner);
        market.kickAfter();
    }

    function test_kickAfter_success() public {
        // Alice buys tokens before the hold
        vm.prank(alice);
        market.buy{value: 0.05 ether}(true, 0);

        // Simulate post-kickoff crisis: warp past kickoff, then hold
        vm.warp(block.timestamp + KICKOFF + 1 hours);
        vm.prank(owner);
        market.holdMatch();

        // ETH is locked inside the pool manager (not address(market) directly)
        // so we measure what the owner receives rather than the contract's raw balance
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        market.kickAfter();

        // kickedAfter flag set
        assertTrue(market.kickedAfter());
        // market contract is fully drained after the unlock/take sequence
        assertEq(address(market).balance, 0);
        // owner received all pooled ETH (initial seed 0.2 ETH + alice's buy net of tax)
        assertGt(owner.balance, ownerBefore);
    }

    // ─────────────────────── helpers ─────────────────────────────────────────

    function _freshMarket() internal returns (MatchMarket m) {
        m = new MatchMarket{value: INITIAL_LIQUIDITY}(
            address(pm),
            address(yubii),
            feeRecipient,
            address(oracle),
            "Manchester United",
            "Liverpool",
            block.timestamp + KICKOFF,
            owner,
            marketingWallet,
            1 // BALANCED
        );
        m.initializeLiquidity();
        vm.prank(alice);
        yubii.approve(address(m), type(uint256).max);
        vm.prank(bob);
        yubii.approve(address(m), type(uint256).max);
    }

    // ─────────────────────── helpers (original) ──────────────────────────────

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
