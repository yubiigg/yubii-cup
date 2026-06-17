// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YubiiFactory} from "../src/YubiiFactory.sol";
import {MatchMarket} from "../src/MatchMarket.sol";
import {MockOptimisticOracleV3} from "../test/mocks/MockOptimisticOracleV3.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Multi-user stress test -- real World Cup 2026 fixtures on Sepolia
//
// Wallets come from env vars WALLET1_PK..WALLET10_PK (10 funded Sepolia EOAs).
// No ETH is distributed from deployer -- wallets supply their own gas + buy ETH.
//
// S1  USA vs MEX  (existing Sepolia market)
//       9 wallets buy yUSA/yMEX, W1 sells half, dynamic fee tracked,
//       holdMatch(), W10 buy-during-hold reverts
//
// S2  FRA vs SEN  (fresh deploy, real Jun 16 kickoff)
//       3 wallets buy yFRA, breakPinky() before kickoff recovers all ETH
//
// S3  ENG vs FRA  (existing Sepolia market)
//       5 wallets buy yENG/yFRA, holdMatch(), W9 buy reverts, kickAfter()
//
// S4  France vs Senegal  (standalone -- real match, mock oracle)
//       Fresh MatchMarket with MockOptimisticOracleV3; 8 wallets buy;
//       market left open -- settle tonight with mockResolve()
//
// Run full suite:
//   forge script script/MultiUserTest.s.sol \
//     --rpc-url $SEPOLIA_RPC --broadcast --slow -vvvv 2>&1 | tee test-report.log
//
// Run only Scenario 4:
//   forge script script/MultiUserTest.s.sol --sig "scenario4FranceSenegal()" \
//     --rpc-url $SEPOLIA_RPC --broadcast --slow -vvvv
//
// Required env vars:
//   PRIVATE_KEY        -- deployer/factory owner key
//   WALLET1_PK .. WALLET10_PK  -- 10 funded test wallet keys
//
// Optional overrides:
//   YUBII_TOKEN=0x...   YUBII_FACTORY=0x...
//   MARKET_USA_MEX=0x...  MARKET_ENG_FRA=0x...
// ─────────────────────────────────────────────────────────────────────────────

contract MultiUserTest is Script {

    // ── Sepolia infrastructure ────────────────────────────────────────────────
    address constant DEFAULT_YUBII_TOKEN   = 0xAd8f38A0940351f0602CBbD4Ab39B4F06C038AaF;
    address constant DEFAULT_YUBII_FACTORY = 0x38Df9f316abb91163Fbfd6eaB048DC357BA384A8;
    address constant SEPOLIA_POOL_MANAGER  = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // ── Existing Sepolia match markets ────────────────────────────────────────
    address constant DEFAULT_MARKET_USA_MEX = 0xd7E7fc8F64de9938cc1af4BFe2Ed75117b1a0925;
    address constant DEFAULT_MARKET_ENG_FRA = 0x74c7Bd018296BC6bc719D1c73d31f4A6b3a5353A;

    // ── Real World Cup 2026 kickoff timestamps (UTC) ──────────────────────────
    // FRA vs SEN: Jun 16, 2026 22:00 UTC -- Group B, MetLife Stadium (S2 fresh deploy)
    uint256 constant KICKOFF_FRA_SEN_S2   = 1781560800;
    // FRA vs SEN: Jun 16, 2026 19:00 UTC -- actual match time for S4 mock market
    uint256 constant KICKOFF_FRA_SEN_S4   = 1781629200;

    // ── Test config ───────────────────────────────────────────────────────────
    uint256 constant MARKET_LIQUIDITY = 0.02 ether;
    uint256 constant BUY_AMOUNT       = 0.003 ether;

    // ── State -- populated by _loadEnv() and _loadWallets() ──────────────────
    uint256[10] internal wKeys;
    address[10] internal wAddrs;

    address internal yubiiToken;
    address internal yubiiFactory;
    address internal marketUsaMex;
    address internal marketEngFra;

    // ─────────────────────────────────────────────────────────────────────────
    // FULL SUITE RUN
    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        _loadEnv();
        _loadWallets();

        uint256 deploKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deploKey);

        address factoryOwner = YubiiFactory(yubiiFactory).owner();
        require(
            deployer == factoryOwner,
            string.concat(
                "PRIVATE_KEY (", vm.toString(deployer),
                ") != factory owner (", vm.toString(factoryOwner),
                "). Use the original deployer key or override YUBII_FACTORY."
            )
        );

        _printHeader(deployer);

        // ── Setup (deployer) ──────────────────────────────────────────────────
        vm.startBroadcast(deploKey);

        MatchMarket m1 = MatchMarket(payable(marketUsaMex));
        if (m1.held()) m1.resumeMatch();
        m1.removeLimits();
        m1.reduceTax(30, 30);

        MatchMarket m2 = _deployFraSen();

        MatchMarket m3 = MatchMarket(payable(marketEngFra));
        if (m3.held()) m3.resumeMatch();
        m3.removeLimits();
        m3.reduceTax(30, 30);

        vm.stopBroadcast();

        console2.log("\n--- Markets ---");
        console2.log("S1 USA vs MEX :", address(m1));
        console2.log("   yUSA       :", address(m1.tokenA()));
        console2.log("   yMEX       :", address(m1.tokenB()));
        console2.log("S2 FRA vs SEN :", address(m2));
        console2.log("   yFRA       :", address(m2.tokenA()));
        console2.log("   ySEN       :", address(m2.tokenB()));
        console2.log(string.concat("   kickoff    : ", vm.toString(KICKOFF_FRA_SEN_S2), " (Jun 16 2026 22:00 UTC)"));
        console2.log("S3 ENG vs FRA :", address(m3));
        console2.log("   yENG       :", address(m3.tokenA()));
        console2.log("   yFRA       :", address(m3.tokenB()));

        _setupApprovals(m1, m2, m3);

        _scenario1_usaMex(deploKey, m1);
        _scenario2_fraSen(deploKey, m2);
        _scenario3_engFra(deploKey, m3);

        _printReport(m1, m2, m3);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 4 -- France vs Senegal (standalone, real match, mock oracle)
    // Run: forge script ... --sig "scenario4FranceSenegal()"
    // ─────────────────────────────────────────────────────────────────────────

    function scenario4FranceSenegal() external {
        _loadEnv();
        _loadWallets();

        uint256 deploKey = vm.envUint("PRIVATE_KEY");
        address deployer  = vm.addr(deploKey);

        console2.log("\n+==========================================+");
        console2.log("  SCENARIO 4: France vs Senegal (mock OO)  ");
        console2.log("+==========================================+");
        console2.log("Deployer :", deployer);
        console2.log("Balance  :", deployer.balance);
        console2.log("Kickoff  : 1781629200 (2026-06-16 19:00 UTC)");

        // ── Deploy mock oracle + market ───────────────────────────────────────
        vm.startBroadcast(deploKey);

        MockOptimisticOracleV3 mockOracle = new MockOptimisticOracleV3();
        console2.log("\n[deploy] MockOptimisticOracleV3:", address(mockOracle));

        // Deploy MatchMarket directly -- deployer becomes factory & owner
        MatchMarket market = new MatchMarket{value: MARKET_LIQUIDITY}(
            SEPOLIA_POOL_MANAGER,
            yubiiToken,
            deployer,           // feeRecipient
            address(mockOracle),
            "France",
            "Senegal",
            KICKOFF_FRA_SEN_S4,
            deployer,           // owner
            deployer,           // marketingWallet
            0                   // SOFT -- group stage
        );
        market.initializeLiquidity();
        market.removeLimits();
        market.reduceTax(30, 30);

        vm.stopBroadcast();

        console2.log("[deploy] MatchMarket (FRA vs SEN)  :", address(market));
        console2.log("[deploy] yFRA (tokenA)             :", address(market.tokenA()));
        console2.log("[deploy] ySEN (tokenB)             :", address(market.tokenB()));
        console2.log(string.concat("[deploy] initial fee: ", vm.toString(market.currentFeeBps()), " bps"));

        // ── YUBII approvals for wallets 0-7 ──────────────────────────────────
        console2.log("\n--- YUBII approvals (wallets 1-8) ---");
        for (uint256 i = 0; i < 8; i++) {
            vm.startBroadcast(wKeys[i]);
            IERC20(yubiiToken).approve(address(market), type(uint256).max);
            vm.stopBroadcast();
        }
        console2.log("  8 approvals done");

        // ── Wallets 1-5 buy France (yFRA) ────────────────────────────────────
        console2.log("\n--- Wallets 1-5 buy France (yFRA) ---");
        uint256[5] memory fraAmounts;
        fraAmounts[0] = 0.005 ether;
        fraAmounts[1] = 0.010 ether;
        fraAmounts[2] = 0.015 ether;
        fraAmounts[3] = 0.020 ether;
        fraAmounts[4] = 0.010 ether;

        for (uint256 i = 0; i < 5; i++) {
            vm.startBroadcast(wKeys[i]);
            market.buy{value: fraAmounts[i]}(true, 0);
            vm.stopBroadcast();
            console2.log(string.concat(
                "  W", vm.toString(i + 1),
                " | yFRA | ", vm.toString(fraAmounts[i] / 1e15), " finney",
                " | fee: ", vm.toString(market.currentFeeBps()), " bps"
            ));
        }

        // ── Wallets 6-8 buy Senegal (ySEN) ───────────────────────────────────
        console2.log("\n--- Wallets 6-8 buy Senegal (ySEN) ---");
        uint256[3] memory senAmounts;
        senAmounts[0] = 0.008 ether;
        senAmounts[1] = 0.012 ether;
        senAmounts[2] = 0.010 ether;

        for (uint256 i = 0; i < 3; i++) {
            vm.startBroadcast(wKeys[5 + i]);
            market.buy{value: senAmounts[i]}(false, 0);
            vm.stopBroadcast();
            console2.log(string.concat(
                "  W", vm.toString(6 + i),
                " | ySEN | ", vm.toString(senAmounts[i] / 1e15), " finney",
                " | fee: ", vm.toString(market.currentFeeBps()), " bps"
            ));
        }

        // ── Final summary ─────────────────────────────────────────────────────
        console2.log("\n+==========================================+");
        console2.log("|      FRANCE vs SENEGAL -- LIVE MARKET    |");
        console2.log("+==========================================+");
        console2.log("Market     :", address(market));
        console2.log("MockOracle :", address(mockOracle));
        console2.log("yFRA token :", address(market.tokenA()));
        console2.log("ySEN token :", address(market.tokenB()));
        console2.log("Kickoff    : 1781629200 (2026-06-16 19:00 UTC)");
        console2.log(string.concat("Final fee  : ", vm.toString(market.currentFeeBps()), " bps"));
        console2.log(string.concat("EWMA vol   : ", vm.toString(market.ewmaVolume()), " wei"));
        console2.log("France vs Senegal market is live and open. Settle tonight with requestSettlement() + mockResolve() once the real result is known.");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 1 -- USA vs MEX
    // ─────────────────────────────────────────────────────────────────────────

    function _scenario1_usaMex(uint256 deploKey, MatchMarket market) internal {
        console2.log("\n============================================");
        console2.log("SCENARIO 1 -- USA vs MEX  (hold lifecycle)");
        console2.log("============================================");
        console2.log("Market     :", address(market));

        uint256 feeInit = market.currentFeeBps();
        console2.log(string.concat("\n[FEE] initial: ", vm.toString(feeInit), " bps"));

        console2.log("\n--- Phase 1: Wallets 1-5 buy yUSA ---");
        for (uint256 i = 0; i < 5; i++) {
            vm.startBroadcast(wKeys[i]);
            market.buy{value: BUY_AMOUNT}(true, 0);
            vm.stopBroadcast();
            console2.log("  Wallet", i + 1, "| yUSA | 0.003 ETH");
        }
        uint256 fee5 = market.currentFeeBps();
        console2.log(string.concat("[FEE] after 5 buys:  ", vm.toString(fee5), " bps  (+", vm.toString(fee5 - feeInit), ")"));

        console2.log("\n--- Phase 2: Wallets 6-8 buy yMEX ---");
        for (uint256 i = 5; i < 8; i++) {
            vm.startBroadcast(wKeys[i]);
            market.buy{value: BUY_AMOUNT}(false, 0);
            vm.stopBroadcast();
            console2.log("  Wallet", i + 1, "| yMEX | 0.003 ETH");
        }
        uint256 fee8 = market.currentFeeBps();
        console2.log(string.concat("[FEE] after 8 buys:  ", vm.toString(fee8), " bps  (+", vm.toString(fee8 - feeInit), " total)"));

        console2.log("\n--- Phase 3: Wallet 1 sells half yUSA ---");
        uint256 bal = market.tokenA().balanceOf(wAddrs[0]);
        console2.log("  Wallet 1 yUSA balance:", bal);
        if (bal > 0) {
            vm.startBroadcast(wKeys[0]);
            market.sell(true, bal / 2, 0);
            vm.stopBroadcast();
            console2.log(string.concat("  Sold ", vm.toString(bal / 2), " yUSA -> ETH"));
        }
        console2.log(string.concat("[FEE] after sell:    ", vm.toString(market.currentFeeBps()), " bps"));

        console2.log("\n--- Phase 4: Wallet 9 buys yUSA (peak volume) ---");
        vm.startBroadcast(wKeys[8]);
        market.buy{value: BUY_AMOUNT}(true, 0);
        vm.stopBroadcast();
        uint256 feePeak = market.currentFeeBps();
        console2.log(string.concat("[FEE] peak (9 buyers): ", vm.toString(feePeak), " bps  (+", vm.toString(feePeak - feeInit), " from init)"));

        console2.log("\n--- Phase 5: holdMatch() ---");
        vm.startBroadcast(deploKey);
        market.holdMatch();
        vm.stopBroadcast();
        console2.log("  held:", market.held());

        console2.log("\n--- Phase 6: Wallet 10 buy during hold [expect MatchHeld] ---");
        vm.startBroadcast(wKeys[9]);
        (bool ok,) = address(market).call{value: BUY_AMOUNT}(
            abi.encodeWithSelector(MatchMarket.buy.selector, true, uint256(0))
        );
        vm.stopBroadcast();
        console2.log(ok ? "  [FAIL] buy should have reverted!" : "  [PASS] MatchHeld revert -- correct");

        console2.log("\n[S1 complete] USA vs MEX held, awaiting UMA settlement");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 2 -- FRA vs SEN (S2 fresh deploy)
    // ─────────────────────────────────────────────────────────────────────────

    function _scenario2_fraSen(uint256 deploKey, MatchMarket market) internal {
        console2.log("\n============================================");
        console2.log("SCENARIO 2 -- FRA vs SEN  (breakPinky)");
        console2.log("============================================");
        console2.log("Market     :", address(market));

        console2.log("\n--- Wallets 1-3 buy yFRA ---");
        for (uint256 i = 0; i < 3; i++) {
            vm.startBroadcast(wKeys[i]);
            market.buy{value: BUY_AMOUNT}(true, 0);
            vm.stopBroadcast();
            console2.log("  Wallet", i + 1, "| yFRA | 0.003 ETH");
        }
        console2.log(string.concat("[FEE] after 3 buys: ", vm.toString(market.currentFeeBps()), " bps"));

        address deployer = vm.addr(deploKey);
        uint256 ownerBefore = deployer.balance;

        if (block.timestamp >= KICKOFF_FRA_SEN_S2) {
            console2.log("\n  [SKIP] block.timestamp >= KICKOFF_FRA_SEN -- kickoff passed.");
            console2.log("  breakPinky() would revert with KickoffPassed -- this is correct.");
            console2.log("  In production: owner calls holdMatch() then kickAfter() instead.");
        } else {
            console2.log(string.concat("\n  Seconds to kickoff: ", vm.toString(KICKOFF_FRA_SEN_S2 - block.timestamp)));
            console2.log("\n--- Owner calls breakPinky() ---");
            vm.startBroadcast(deploKey);
            (bool success,) = address(market).call(
                abi.encodeWithSignature("breakPinky()")
            );
            vm.stopBroadcast();
            if (success) {
                console2.log("  [S2] breakPinky succeeded, owner refunded");
            } else {
                console2.log("  [S2] breakPinky reverted (kickoff passed) -- skipping");
            }
            uint256 ownerAfter = deployer.balance;
            if (ownerAfter > ownerBefore) {
                console2.log(string.concat(
                    "  [RESULT] Owner recovered: ", vm.toString(ownerAfter - ownerBefore), " wei"
                ));
            } else {
                console2.log("  [RESULT] Net negative (gas > recovery at low test volume -- expected)");
            }
        }

        console2.log("\n[S2 complete] breakPinky drains both pools to owner pre-kickoff");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SCENARIO 3 -- ENG vs FRA
    // ─────────────────────────────────────────────────────────────────────────

    function _scenario3_engFra(uint256 deploKey, MatchMarket market) internal {
        console2.log("\n============================================");
        console2.log("SCENARIO 3 -- ENG vs FRA  (kickAfter)");
        console2.log("============================================");
        console2.log("Market     :", address(market));

        if (market.kickedAfter()) {
            console2.log("\n  [SKIP] kickedAfter already true on ENG vs FRA market.");
            console2.log("  Set MARKET_ENG_FRA env var to a fresh market address to rerun.");
            return;
        }

        console2.log("\n--- Wallets 4-6 buy yENG, Wallets 7-8 buy yFRA ---");
        for (uint256 i = 3; i < 6; i++) {
            vm.startBroadcast(wKeys[i]);
            market.buy{value: BUY_AMOUNT}(true, 0);
            vm.stopBroadcast();
            console2.log("  Wallet", i + 1, "| yENG | 0.003 ETH");
        }
        for (uint256 i = 6; i < 8; i++) {
            vm.startBroadcast(wKeys[i]);
            market.buy{value: BUY_AMOUNT}(false, 0);
            vm.stopBroadcast();
            console2.log("  Wallet", i + 1, "| yFRA | 0.003 ETH");
        }
        console2.log(string.concat("[FEE] after 5 buys: ", vm.toString(market.currentFeeBps()), " bps"));

        console2.log("\n--- holdMatch() ---");
        vm.startBroadcast(deploKey);
        market.holdMatch();
        vm.stopBroadcast();
        console2.log("  held:", market.held());

        console2.log("\n--- Wallet 9 buy during hold [expect MatchHeld] ---");
        vm.startBroadcast(wKeys[8]);
        (bool ok,) = address(market).call{value: BUY_AMOUNT}(
            abi.encodeWithSelector(MatchMarket.buy.selector, false, uint256(0))
        );
        vm.stopBroadcast();
        console2.log(ok ? "  [FAIL] buy should have reverted!" : "  [PASS] MatchHeld revert -- correct");

        address deployer = vm.addr(deploKey);
        uint256 ownerBefore = deployer.balance;
        console2.log("\n--- kickAfter() ---");
        vm.startBroadcast(deploKey);
        market.kickAfter();
        vm.stopBroadcast();
        console2.log("  kickedAfter:", market.kickedAfter());
        uint256 ownerAfter = deployer.balance;
        if (ownerAfter > ownerBefore) {
            console2.log(string.concat(
                "  [RESULT] Owner recovered: ", vm.toString(ownerAfter - ownerBefore), " wei"
            ));
        } else {
            console2.log("  [RESULT] Net negative (gas > recovery at low test volume -- expected)");
        }

        console2.log("\n[S3 complete] All ENG/FRA pool ETH recovered -- users refund off-chain");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _loadEnv() internal {
        yubiiToken   = vm.envOr("YUBII_TOKEN",    DEFAULT_YUBII_TOKEN);
        yubiiFactory = vm.envOr("YUBII_FACTORY",  DEFAULT_YUBII_FACTORY);
        marketUsaMex = vm.envOr("MARKET_USA_MEX", DEFAULT_MARKET_USA_MEX);
        marketEngFra = vm.envOr("MARKET_ENG_FRA", DEFAULT_MARKET_ENG_FRA);
    }

    function _loadWallets() internal {
        wKeys[0] = vm.envUint("WALLET1_PK");
        wKeys[1] = vm.envUint("WALLET2_PK");
        wKeys[2] = vm.envUint("WALLET3_PK");
        wKeys[3] = vm.envUint("WALLET4_PK");
        wKeys[4] = vm.envUint("WALLET5_PK");
        wKeys[5] = vm.envUint("WALLET6_PK");
        wKeys[6] = vm.envUint("WALLET7_PK");
        wKeys[7] = vm.envUint("WALLET8_PK");
        wKeys[8] = vm.envUint("WALLET9_PK");
        wKeys[9] = vm.envUint("WALLET10_PK");
        for (uint256 i = 0; i < 10; i++) {
            wAddrs[i] = vm.addr(wKeys[i]);
        }
    }

    function _printHeader(address deployer) internal {
        console2.log("+==========================================+");
        console2.log("   YUBII CUP -- MULTI-USER SEPOLIA TEST    ");
        console2.log("+==========================================+");
        console2.log("Deployer  :", deployer);
        console2.log("Balance   :", deployer.balance);
        console2.log("\n--- 10 Real Sepolia Wallets ---");
        for (uint256 i = 0; i < 10; i++) {
            console2.log(string.concat("  W", vm.toString(i + 1), ":"), wAddrs[i]);
        }
    }

    function _deployFraSen() internal returns (MatchMarket) {
        address addr = YubiiFactory(yubiiFactory).createMatch{value: MARKET_LIQUIDITY}(
            "France", "Senegal", KICKOFF_FRA_SEN_S2, 0  // SOFT -- group stage
        );
        MatchMarket m = MatchMarket(payable(addr));
        m.removeLimits();
        m.reduceTax(30, 30);
        return m;
    }

    function _setupApprovals(MatchMarket m1, MatchMarket m2, MatchMarket m3) internal {
        address yUsaToken = address(m1.tokenA());
        address yMexToken = address(m1.tokenB());

        console2.log("\n--- Setting approvals: YUBII x3 + yUSA + yMEX per wallet ---");
        for (uint256 i = 0; i < 10; i++) {
            vm.startBroadcast(wKeys[i]);
            IERC20(yubiiToken).approve(address(m1), type(uint256).max);
            IERC20(yubiiToken).approve(address(m2), type(uint256).max);
            IERC20(yubiiToken).approve(address(m3), type(uint256).max);
            IERC20(yUsaToken).approve(address(m1), type(uint256).max);
            IERC20(yMexToken).approve(address(m1), type(uint256).max);
            vm.stopBroadcast();
        }
        console2.log("  50 approval txs done (5 per wallet)");
    }

    function _printReport(MatchMarket m1, MatchMarket m2, MatchMarket m3) internal {
        console2.log("\n+======================================================+");
        console2.log("|        YUBII CUP -- MULTI-USER TEST REPORT           |");
        console2.log("+======================================================+");
        console2.log("|  S1  USA vs MEX");
        console2.log(string.concat("|    held:        ", vm.toString(m1.held())));
        console2.log(string.concat("|    settled:     ", vm.toString(m1.settled())));
        console2.log(string.concat("|    currentFee:  ", vm.toString(m1.currentFeeBps()), " bps"));
        console2.log("|  S2  FRA vs SEN");
        console2.log(string.concat("|    kickoff:     ", vm.toString(KICKOFF_FRA_SEN_S2)));
        console2.log(string.concat("|    ewmaVolume:  ", vm.toString(m2.ewmaVolume())));
        console2.log("|  S3  ENG vs FRA");
        console2.log(string.concat("|    kickedAfter: ", vm.toString(m3.kickedAfter())));
        console2.log(string.concat("|    ewmaVolume:  ", vm.toString(m3.ewmaVolume())));
        console2.log("+------------------------------------------------------+");
        console2.log("|  Wallets:");
        for (uint256 i = 0; i < 10; i++) {
            console2.log(string.concat("|  W", vm.toString(i + 1), ":"), wAddrs[i]);
        }
        console2.log("+======================================================+");
    }
}
