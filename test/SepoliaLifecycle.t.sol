// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MatchMarket} from "../src/MatchMarket.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Fork test: full MAN vs LIV lifecycle against Sepolia state
//
// Run:
//   forge test --match-contract SepoliaLifecycle \
//              --fork-url $SEPOLIA_RPC -vv
// ─────────────────────────────────────────────────────────────────────────────
contract SepoliaLifecycleTest is Test {
    // ── deployed addresses (Sepolia) ──────────────────────────────────────────
    MatchMarket constant MARKET   = MatchMarket(payable(0x04Bf83E23C964fbeC8e5e581524A5E08544B4D04));
    address     constant YUBII    = 0x86Ac29d594a47840eE4197ecb8Cc01ea4e025cc7;
    address     constant WMAN     = 0x5A7F4991334E2Ed29c86DD2bBB8fc9999DD21d7d; // tokenA
    address     constant WLIV     = 0xB8dF91F0a1861214D494f11F1fAD68F0c9513757; // tokenB
    address     constant ORACLE   = 0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944; // UMA OO v3
    uint256     constant KICKOFF  = 1781902884; // 2026-06-20

    // ── test actors ───────────────────────────────────────────────────────────
    address alice = makeAddr("alice"); // buys WMAN (MAN fan)
    address bob   = makeAddr("bob");   // buys WLIV (LIV fan)

    // ── ETH amounts ───────────────────────────────────────────────────────────
    uint256 constant BUY_ETH = 0.005 ether;

    function setUp() public {
        vm.createSelectFork("sepolia"); // uses [rpc_endpoints] in foundry.toml

        // Fund actors with ETH
        vm.deal(alice, 1 ether);
        vm.deal(bob,   1 ether);

        // Deal YUBII for protocol fees (0.3 % of BUY_ETH = trivial amount)
        deal(YUBII, alice, 1_000 ether);
        deal(YUBII, bob,   1_000 ether);

        _logMarketState();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Individual step tests (run separately for debugging)
    // ─────────────────────────────────────────────────────────────────────────

    function test_step1_buyWMAN() public {
        uint256 wmanBefore = IERC20(WMAN).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(YUBII).approve(address(MARKET), type(uint256).max);
        MARKET.buy{value: BUY_ETH}(true, 0);
        vm.stopPrank();

        uint256 received = IERC20(WMAN).balanceOf(alice) - wmanBefore;
        assertGt(received, 0, "Alice should receive WMAN");
        console2.log("[step 1] Alice WMAN received:", received);
    }

    function test_step2_buyWLIV() public {
        uint256 wlivBefore = IERC20(WLIV).balanceOf(bob);

        vm.startPrank(bob);
        IERC20(YUBII).approve(address(MARKET), type(uint256).max);
        MARKET.buy{value: BUY_ETH}(false, 0);
        vm.stopPrank();

        uint256 received = IERC20(WLIV).balanceOf(bob) - wlivBefore;
        assertGt(received, 0, "Bob should receive WLIV");
        console2.log("[step 2] Bob WLIV received:", received);
    }

    function test_step3_settlement_MAN_wins() public {
        _buyBoth();

        // Warp past kickoff
        vm.warp(KICKOFF + 1 hours);
        console2.log("[step 3] Warped to:", block.timestamp, "(kickoff +1h)");

        // Mock UMA OO assertTruth — intercepts any call to the function,
        // returns a deterministic assertionId without touching the real oracle.
        bytes32 assertionId = keccak256("MAN_WINS_2026");
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector),
            abi.encode(assertionId)
        );

        // Request settlement: claimedWinner = 1 (MAN = teamA)
        bytes32 returned = MARKET.requestSettlement(
            1,              // MAN wins
            address(this),  // asserter (us, no bond needed for mock)
            address(0),     // bond currency
            0               // bond amount
        );
        assertEq(returned, assertionId, "assertionId mismatch");
        assertEq(MARKET.pendingAssertionId(), assertionId);
        console2.log("[step 3] Settlement requested, assertionId:", vm.toString(assertionId));

        // Simulate UMA OO resolving the assertion as truthful
        vm.prank(ORACLE);
        MARKET.assertionResolvedCallback(assertionId, true);

        assertTrue(MARKET.settled(), "Market must be settled");
        assertEq(MARKET.winner(), 1, "Winner must be MAN (teamA=1)");
        console2.log("[step 3] Market settled. Winner:", MARKET.winner());
        console2.log("[step 3] Total ETH for redemption:", MARKET.totalSettledETH());
    }

    function test_step4_redeem_WMAN() public {
        // Run prior steps inline
        _buyBoth();
        _settleMAN();

        uint256 aliceWman = IERC20(WMAN).balanceOf(alice);
        uint256 aliceEthBefore = alice.balance;
        uint256 totalSettled = MARKET.totalSettledETH();
        uint256 winnerSupply = MARKET.settledWinnerSupply();

        uint256 expectedEth = (aliceWman * totalSettled) / winnerSupply;
        console2.log("[step 4] Alice WMAN to redeem:", aliceWman);
        console2.log("[step 4] Expected ETH out:", expectedEth);

        vm.startPrank(alice);
        IERC20(WMAN).approve(address(MARKET), aliceWman);
        MARKET.redeem(aliceWman);
        vm.stopPrank();

        uint256 ethReceived = alice.balance - aliceEthBefore;
        assertApproxEqAbs(ethReceived, expectedEth, 1e9, "ETH received should match formula");
        assertEq(IERC20(WMAN).balanceOf(alice), 0, "All WMAN burned");
        console2.log("[step 4] Alice ETH received:", ethReceived);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Full end-to-end test
    // ─────────────────────────────────────────────────────────────────────────

    function test_fullLifecycle() public {
        console2.log("\n======= YUBII CUP: MAN vs LIV - FULL LIFECYCLE =======");

        // ── 1. Buy $WMAN ──────────────────────────────────────────────────────
        console2.log("\n--- Step 1: Alice buys WMAN ($MAN fan) ---");
        vm.startPrank(alice);
        IERC20(YUBII).approve(address(MARKET), type(uint256).max);
        MARKET.buy{value: BUY_ETH}(true, 0);
        vm.stopPrank();

        uint256 aliceWman = IERC20(WMAN).balanceOf(alice);
        assertGt(aliceWman, 0);
        console2.log("  Alice WMAN balance :", aliceWman);
        console2.log("  Alice ETH spent    :", BUY_ETH);

        // ── 2. Buy $WLIV ──────────────────────────────────────────────────────
        console2.log("\n--- Step 2: Bob buys WLIV ($LIV fan) ---");
        vm.startPrank(bob);
        IERC20(YUBII).approve(address(MARKET), type(uint256).max);
        MARKET.buy{value: BUY_ETH}(false, 0);
        vm.stopPrank();

        uint256 bobWliv = IERC20(WLIV).balanceOf(bob);
        assertGt(bobWliv, 0);
        console2.log("  Bob WLIV balance   :", bobWliv);
        console2.log("  Bob ETH spent      :", BUY_ETH);

        // ── 3. Simulate settlement: MAN wins ──────────────────────────────────
        console2.log("\n--- Step 3: Match settles - Manchester United wins ---");
        _settleMAN();
        assertEq(MARKET.winner(), 1);
        console2.log("  Winner             : teamA (MAN)");
        console2.log("  Total ETH pooled   :", MARKET.totalSettledETH());
        console2.log("  Winner supply snap :", MARKET.settledWinnerSupply());

        // ── 4. Redeem winning WMAN tokens ─────────────────────────────────────
        console2.log("\n--- Step 4: Alice redeems WMAN for ETH ---");
        uint256 aliceEthBefore = alice.balance;

        vm.startPrank(alice);
        IERC20(WMAN).approve(address(MARKET), aliceWman);
        MARKET.redeem(aliceWman);
        vm.stopPrank();

        uint256 aliceEthGained = alice.balance - aliceEthBefore;
        assertGt(aliceEthGained, 0, "Alice must receive ETH");
        assertEq(IERC20(WMAN).balanceOf(alice), 0, "All WMAN burned");
        console2.log("  ETH received       :", aliceEthGained);
        console2.log("  WMAN remaining     :", IERC20(WMAN).balanceOf(alice));

        // ── Bob's WLIV is worthless — winner=1 means only tokenA (WMAN) redeems ──
        // Attempting redeem() would try to burn WMAN from Bob (he has none) and
        // revert with ERC20InsufficientBalance.
        assertEq(MARKET.winner(), 1, "winner is teamA");
        assertGt(IERC20(WLIV).balanceOf(bob), 0, "Bob still holds worthless WLIV");
        console2.log("\n--- Bob (WLIV holder) ---");
        console2.log("  Bob WLIV balance   :", bobWliv, "(worthless - LIV lost)");

        console2.log("\n======= LIFECYCLE COMPLETE =======\n");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _buyBoth() internal {
        vm.startPrank(alice);
        IERC20(YUBII).approve(address(MARKET), type(uint256).max);
        MARKET.buy{value: BUY_ETH}(true, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(YUBII).approve(address(MARKET), type(uint256).max);
        MARKET.buy{value: BUY_ETH}(false, 0);
        vm.stopPrank();
    }

    function _settleMAN() internal {
        vm.warp(KICKOFF + 1 hours);

        bytes32 assertionId = keccak256("MAN_WINS_2026");
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector),
            abi.encode(assertionId)
        );

        MARKET.requestSettlement(1, address(this), address(0), 0);

        vm.prank(ORACLE);
        MARKET.assertionResolvedCallback(assertionId, true);
    }

    function _logMarketState() internal view {
        console2.log("MatchMarket :", address(MARKET));
        console2.log("yMAN (tokenA):", WMAN);
        console2.log("yLIV (tokenB):", WLIV);
        console2.log("Kickoff     :", KICKOFF);
        console2.log("Settled     :", MARKET.settled());
        console2.log("LiquidityA  :", MARKET.liquidityA());
    }
}
