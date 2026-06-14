// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MatchMarket} from "../src/MatchMarket.sol";
import {MockOptimisticOracleV3} from "../test/mocks/MockOptimisticOracleV3.sol";

interface IMockOO {
    function mockResolve(bytes32 assertionId, bool truthfully) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Live interaction script — Sepolia: England vs France
//
//   # Show market state
//   forge script script/Interact.s.sol --rpc-url $SEPOLIA_RPC
//
//   # Buy yENG (teamA, 0.005 ETH)
//   forge script script/Interact.s.sol --sig "buyENG()" \
//     --rpc-url $SEPOLIA_RPC --broadcast
//
//   # Buy yFRA (teamB, 0.005 ETH)
//   forge script script/Interact.s.sol --sig "buyFRA()" \
//     --rpc-url $SEPOLIA_RPC --broadcast
//
//   # Check balances
//   forge script script/Interact.s.sol --sig "checkBalances()" \
//     --rpc-url $SEPOLIA_RPC
//
// Required .env: PRIVATE_KEY, SEPOLIA_RPC
// ─────────────────────────────────────────────────────────────────────────────

interface IYubiiFactory {
    function markets(uint256 index) external view returns (address);
    function freezeLeague() external;
    function thawLeague() external;
}

contract Interact is Script {
    MatchMarket constant MARKET              = MatchMarket(payable(0x19990fD9EDc391aed93779ff21D3d0d6E29054E7));
    address     constant YUBII_TOKEN         = 0xB876aC7cd0A4eBe37b35ed2d08a69D5DD51a2700;
    address     constant MARKETING_WALLET    = 0xfCFA09B1Bc297F7B61401FbfBf76865fE9b12CB0;
    address     constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    MatchMarket constant USA_MEX  = MatchMarket(payable(0xED61ceA1658bF0c2F934882a2A27C4b6948c6207));
    address     constant FACTORY  = 0xA194261A4849043bf6dae1B8EaA69978C52e5746;

    uint256 constant BUY_ETH = 0.005 ether;

    // Set by createMockMatch(); pass these to fullLifecycle()
    address public MOCK_MARKET;
    address public MOCK_ORACLE;

    function _yeng() internal view returns (address) { return address(MARKET.tokenA()); }
    function _yfra() internal view returns (address) { return address(MARKET.tokenB()); }

    // ── default: market state ─────────────────────────────────────────────────

    function run() external view {
        uint256 kickoff = MARKET.kickoffTime();
        console2.log("=== YUBII CUP: ENG vs FRA ===");
        console2.log("Market    :", address(MARKET));
        console2.log("yENG      :", _yeng());
        console2.log("yFRA      :", _yfra());
        console2.log("Kickoff   :", kickoff);
        console2.log("Settled   :", MARKET.settled());
        console2.log("LiquidityA:", MARKET.liquidityA());
        console2.log("LiquidityB:", MARKET.liquidityB());
        if (MARKET.settled()) {
            console2.log("Winner    :", MARKET.winner() == 1 ? "ENG" : "FRA");
            console2.log("Pool ETH  :", MARKET.totalSettledETH());
        }
    }

    // ── buyENG ────────────────────────────────────────────────────────────────

    function buyENG() external {
        uint256 pk     = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        require(!MARKET.settled(), "Market already settled");
        _ensureYubiiApproved(pk, trader);

        uint256 before = IERC20(_yeng()).balanceOf(trader);

        vm.startBroadcast(pk);
        MARKET.buy{value: BUY_ETH}(true, 0);
        vm.stopBroadcast();

        console2.log("yENG received:", IERC20(_yeng()).balanceOf(trader) - before);
        console2.log("yENG balance :", IERC20(_yeng()).balanceOf(trader));
    }

    // ── buyFRA ────────────────────────────────────────────────────────────────

    function buyFRA() external {
        uint256 pk     = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        require(!MARKET.settled(), "Market already settled");
        _ensureYubiiApproved(pk, trader);

        uint256 before = IERC20(_yfra()).balanceOf(trader);

        vm.startBroadcast(pk);
        MARKET.buy{value: BUY_ETH}(false, 0);
        vm.stopBroadcast();

        console2.log("yFRA received:", IERC20(_yfra()).balanceOf(trader) - before);
        console2.log("yFRA balance :", IERC20(_yfra()).balanceOf(trader));
    }

    // ── sellENG ───────────────────────────────────────────────────────────────

    function sellENG() external {
        uint256 pk     = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        uint256 balance = IERC20(_yeng()).balanceOf(trader);
        require(balance > 0, "No yENG to sell");
        _ensureYubiiApproved(pk, trader);

        uint256 ethBefore  = trader.balance;
        uint256 mktBefore  = MARKETING_WALLET.balance;

        vm.startBroadcast(pk);
        IERC20(_yeng()).approve(address(MARKET), balance);
        MARKET.sell(true, balance, 0);
        vm.stopBroadcast();

        console2.log("ETH received        :", trader.balance - ethBefore);
        console2.log("Marketing ETH (new) :", MARKETING_WALLET.balance);
        console2.log("Marketing ETH gained:", MARKETING_WALLET.balance - mktBefore);
    }

    // ── requestSettlementENG ─────────────────────────────────────────────────
    // Claims France (teamB=2) wins. Kickoff is confirmed past on Sepolia.

    function requestSettlementENG() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address asserter = vm.addr(pk);

        require(!MARKET.settled(), "Already settled");
        require(MARKET.pendingAssertionId() == bytes32(0), "Assertion already pending");

        vm.startBroadcast(pk);
        bytes32 assertionId = MARKET.requestSettlement(2, asserter, address(0), 0);
        vm.stopBroadcast();

        console2.log("Assertion ID :", vm.toString(assertionId));
        console2.log("Claimed winner: teamB (France)");
        console2.log("Liveness     : 7200s (~2 hours)");
        console2.log("After liveness, settle with:");
        console2.log("  cast send", address(MARKET.oracle()),
            "\"settleAssertion(bytes32)\"", vm.toString(assertionId));
    }

    // ── redeemFRA ────────────────────────────────────────────────────────────

    function redeemFRA() external {
        uint256 pk     = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        require(MARKET.settled(), "Market not settled yet");
        require(MARKET.winner() == 2, "France did not win; only teamB (yFRA) redeems");

        uint256 yfraBalance = IERC20(_yfra()).balanceOf(trader);
        require(yfraBalance > 0, "No yFRA to redeem");

        uint256 expectedEth = (yfraBalance * MARKET.totalSettledETH()) / MARKET.settledWinnerSupply();
        console2.log("Redeeming yFRA:", yfraBalance);
        console2.log("Expected ETH  :", expectedEth);

        uint256 ethBefore = trader.balance;

        vm.startBroadcast(pk);
        IERC20(_yfra()).approve(address(MARKET), yfraBalance);
        MARKET.redeem(yfraBalance);
        vm.stopBroadcast();

        console2.log("ETH received  :", trader.balance - ethBefore);
        console2.log("yFRA remaining:", IERC20(_yfra()).balanceOf(trader));
    }

    // ── checkBalances ─────────────────────────────────────────────────────────

    function checkBalances() external view {
        address trader = vm.addr(vm.envUint("PRIVATE_KEY"));
        console2.log("=== Balances ===");
        console2.log("yENG (deployer)    :", IERC20(_yeng()).balanceOf(trader));
        console2.log("yFRA (deployer)    :", IERC20(_yfra()).balanceOf(trader));
        console2.log("Marketing ETH      :", MARKETING_WALLET.balance);
    }

    // ── mockSettle ────────────────────────────────────────────────────────────
    // Works only when the market's oracle is a MockOptimisticOracleV3.
    // Operates on the Turkey vs Japan market (separate from ENG vs FRA above).
    // Flow: requestSettlement(teamA=Turkey) if no assertion pending,
    //       then mockResolve → assertionResolvedCallback → market settles instantly.

    MatchMarket constant TUR_JPN = MatchMarket(payable(0x268B2Af65b469987725c872c0b1E50692EabBe4B));
    address     constant REAL_UMA_SEPOLIA = 0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944;

    function mockSettle() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address oracle   = address(TUR_JPN.oracle());

        console2.log("TUR vs JPN market:", address(TUR_JPN));
        console2.log("Oracle           :", oracle);
        require(!TUR_JPN.settled(), "Market already settled");
        require(oracle != REAL_UMA_SEPOLIA,
            "Real UMA oracle detected - mockSettle unavailable. Wait for liveness.");

        vm.startBroadcast(pk);

        // Request settlement if none is pending (teamA = Turkey wins)
        bytes32 assertionId = TUR_JPN.pendingAssertionId();
        if (assertionId == bytes32(0)) {
            assertionId = TUR_JPN.requestSettlement(1, deployer, address(0), 0);
            console2.log("Settlement requested, assertionId:", vm.toString(assertionId));
        } else {
            console2.log("Reusing pending assertionId  :", vm.toString(assertionId));
        }

        // Instant resolution via MockOptimisticOracleV3.mockResolve
        IMockOO(oracle).mockResolve(assertionId, true);

        vm.stopBroadcast();

        console2.log("Settled          :", TUR_JPN.settled());
        console2.log("Winner           :", TUR_JPN.winner() == 1 ? "TUR (teamA)" : "JPN (teamB)");
        console2.log("Total ETH        :", TUR_JPN.totalSettledETH());
    }

    // ── createMockMatch ───────────────────────────────────────────────────────

    function createMockMatch() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        MockOptimisticOracleV3 mockOracle = new MockOptimisticOracleV3();

        MatchMarket m = new MatchMarket{value: 0.005 ether}(
            SEPOLIA_POOL_MANAGER,
            YUBII_TOKEN,
            deployer,             // feeRecipient
            address(mockOracle),
            "Turkey",
            "Japan",
            block.timestamp - 1,  // kickoff already past
            deployer,             // owner
            MARKETING_WALLET,
            1                     // BALANCED fee profile
        );
        m.initializeLiquidity();

        vm.stopBroadcast();

        MOCK_ORACLE = address(mockOracle);
        MOCK_MARKET = address(m);

        console2.log("MOCK_ORACLE    :", MOCK_ORACLE);
        console2.log("MOCK_MARKET    :", MOCK_MARKET);
        console2.log("tokenA (yTURK) :", address(m.tokenA()));
        console2.log("tokenB (yJAPA) :", address(m.tokenB()));
        console2.log("kickoffTime    :", m.kickoffTime());
        console2.log("Pass these to fullLifecycle(mockMarket, mockOracle)");
    }

    // ── fullLifecycle ─────────────────────────────────────────────────────────

    function fullLifecycle(address mockMarket, address mockOracle) external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        MatchMarket m   = MatchMarket(payable(mockMarket));

        console2.log("=== Full Lifecycle: Turkey vs Japan ===");
        console2.log("Market :", mockMarket);
        console2.log("Oracle :", mockOracle);

        // ── 1. Buy yTURK (teamA) with 0.005 ETH ──────────────────────────────
        uint256 mktBefore = MARKETING_WALLET.balance;

        vm.startBroadcast(pk);
        IERC20(YUBII_TOKEN).approve(mockMarket, type(uint256).max);
        m.buy{value: 0.005 ether}(true, 0);
        vm.stopBroadcast();

        uint256 yturkBalance = IERC20(address(m.tokenA())).balanceOf(deployer);
        console2.log("\n[1] Bought yTURK");
        console2.log("    yTURK received  :", yturkBalance);
        console2.log("    Marketing ETH   :", MARKETING_WALLET.balance);
        console2.log("    Buy tax gained  :", MARKETING_WALLET.balance - mktBefore);

        // ── 2. Request settlement: Turkey wins (teamA = 1) ────────────────────
        vm.startBroadcast(pk);
        m.requestSettlement(1, deployer, address(0), 0);
        vm.stopBroadcast();

        // Read assertionId from storage — avoids relying on simulation return value
        bytes32 assertionId = m.pendingAssertionId();
        console2.log("\n[2] Settlement requested");
        console2.log("    assertionId     :", vm.toString(assertionId));

        // ── 3. Mock resolve → assertionResolvedCallback → market settles ──────
        mktBefore = MARKETING_WALLET.balance;

        vm.startBroadcast(pk);
        IMockOO(mockOracle).mockResolve(assertionId, true);
        vm.stopBroadcast();

        console2.log("\n[3] Settled");
        console2.log("    settled         :", m.settled());
        console2.log("    winner          :", m.winner() == 1 ? "Turkey (teamA)" : "Japan (teamB)");
        console2.log("    totalSettledETH :", m.totalSettledETH());
        console2.log("    Settlement fee  :", MARKETING_WALLET.balance - mktBefore);

        // ── 4. Redeem yTURK for ETH ───────────────────────────────────────────
        uint256 ethBefore = deployer.balance;
        mktBefore = MARKETING_WALLET.balance;

        vm.startBroadcast(pk);
        IERC20(address(m.tokenA())).approve(mockMarket, yturkBalance);
        m.redeem(yturkBalance);
        vm.stopBroadcast();

        console2.log("\n[4] Redeemed");
        console2.log("    ETH received    :", deployer.balance - ethBefore);
        console2.log("    yTURK remaining :", IERC20(address(m.tokenA())).balanceOf(deployer));
        console2.log("    Marketing final :", MARKETING_WALLET.balance);
        console2.log("\n=== Lifecycle complete ===");
    }

    // ── testHoldMatch ─────────────────────────────────────────────────────────
    // forge script script/Interact.s.sol --sig "testHoldMatch()" \
    //   --rpc-url $SEPOLIA_RPC --broadcast

    function testHoldMatch() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== testHoldMatch: USA vs MEX ===");
        console2.log("Market :", address(USA_MEX));
        console2.log("held   :", USA_MEX.held());

        // 1. Hold the market
        vm.startBroadcast(pk);
        USA_MEX.holdMatch();
        vm.stopBroadcast();
        console2.log("\n[1] holdMatch() called");
        console2.log("    held :", USA_MEX.held());

        // 2. Attempt to buy - should revert with MatchHeld
        console2.log("\n[2] Attempting buy while held (expect revert)...");
        IERC20(YUBII_TOKEN).approve(address(USA_MEX), type(uint256).max);
        (bool success,) = address(USA_MEX).call{value: 0.001 ether}(
            abi.encodeWithSignature("buy(bool,uint256)", true, 0)
        );
        console2.log("    buy reverted:", !success);

        // 3. Resume the market
        vm.startBroadcast(pk);
        USA_MEX.resumeMatch();
        vm.stopBroadcast();
        console2.log("\n[3] resumeMatch() called");
        console2.log("    held :", USA_MEX.held());

        // 4. Buy successfully
        uint256 tokensBefore = IERC20(address(USA_MEX.tokenA())).balanceOf(deployer);
        vm.startBroadcast(pk);
        IERC20(0xacB4474196bDA1d8ba0ECc7B3B72178C09cd2F21).approve(address(USA_MEX), type(uint256).max);
        USA_MEX.buy{value: 0.001 ether}(true, 0);
        vm.stopBroadcast();
        uint256 received = IERC20(address(USA_MEX.tokenA())).balanceOf(deployer) - tokensBefore;
        console2.log("\n[4] Buy after resume succeeded");
        console2.log("    yUSA received:", received);
    }

    // ── testFreezeLeague ──────────────────────────────────────────────────────
    // forge script script/Interact.s.sol --sig "testFreezeLeague()" \
    //   --rpc-url $SEPOLIA_RPC --broadcast

    function testFreezeLeague() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        console2.log("=== testFreezeLeague: Factory ===");
        console2.log("Factory :", FACTORY);

        address firstMarket = IYubiiFactory(FACTORY).markets(0);
        console2.log("markets(0) :", firstMarket);
        console2.log("held before:", MatchMarket(payable(firstMarket)).held());

        // 1. Freeze all markets
        vm.startBroadcast(pk);
        IYubiiFactory(FACTORY).freezeLeague();
        vm.stopBroadcast();
        console2.log("\n[1] freezeLeague() called");
        console2.log("    held :", MatchMarket(payable(firstMarket)).held());

        // 2. Thaw all markets
        vm.startBroadcast(pk);
        IYubiiFactory(FACTORY).thawLeague();
        vm.stopBroadcast();
        console2.log("\n[2] thawLeague() called");
        console2.log("    held :", MatchMarket(payable(firstMarket)).held());
    }

    // ── testReclaimETH ────────────────────────────────────────────────────────
    // forge script script/Interact.s.sol --sig "testReclaimETH()" \
    //   --rpc-url $SEPOLIA_RPC --broadcast

    function testReclaimETH() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== testReclaimETH: USA vs MEX ===");
        console2.log("Market  :", address(USA_MEX));

        uint256 ethBefore = deployer.balance;
        uint256 marketBal = address(USA_MEX).balance;
        console2.log("Deployer ETH before :", ethBefore);
        console2.log("Market ETH balance  :", marketBal);

        // 1. Hold the market
        vm.startBroadcast(pk);
        USA_MEX.holdMatch();
        vm.stopBroadcast();
        console2.log("\n[1] holdMatch() called");

        // 2. Reclaim ETH (only succeeds if market holds ETH - adjust amount if needed)
        uint256 reclaimAmt = marketBal >= 0.001 ether ? 0.001 ether : marketBal;
        if (reclaimAmt == 0) {
            console2.log("\n[2] Market has no ETH to reclaim - skipping reclaimETH");
        } else {
            vm.startBroadcast(pk);
            USA_MEX.reclaimETH(deployer, reclaimAmt);
            vm.stopBroadcast();
            console2.log("\n[2] reclaimETH called, amount:", reclaimAmt);
            console2.log("    Deployer ETH after  :", deployer.balance);
            console2.log("    ETH gained          :", deployer.balance - ethBefore);
        }

        // 3. Resume so the market stays usable
        vm.startBroadcast(pk);
        USA_MEX.resumeMatch();
        vm.stopBroadcast();
        console2.log("\n[3] resumeMatch() called - market restored");
        console2.log("    held :", USA_MEX.held());
    }

    // ── testRemoveLimits ──────────────────────────────────────────────────────
    // forge script script/Interact.s.sol --sig "testRemoveLimits()" \
    //   --rpc-url $SEPOLIA_RPC --broadcast

    function testRemoveLimits() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address yubii   = 0xacB4474196bDA1d8ba0ECc7B3B72178C09cd2F21;

        console2.log("=== testRemoveLimits: USA vs MEX ===");
        console2.log("maxBuyETH     :", USA_MEX.maxBuyETH());
        console2.log("limitsRemoved :", USA_MEX.limitsRemoved());

        // 1. Attempt 0.02 ETH buy - should revert with BuyLimitExceeded
        console2.log("\n[1] Attempting 0.02 ETH buy (limit is 0.01 - expect revert)...");
        (bool success,) = address(USA_MEX).call{value: 0.02 ether}(
            abi.encodeWithSignature("buy(bool,uint256)", true, 0)
        );
        console2.log("    buy reverted:", !success);

        // 2. Remove limits
        vm.startBroadcast(pk);
        USA_MEX.removeLimits();
        vm.stopBroadcast();
        console2.log("\n[2] removeLimits() called");
        console2.log("    limitsRemoved:", USA_MEX.limitsRemoved());

        // 3. Buy 0.02 ETH successfully
        uint256 tokensBefore = IERC20(address(USA_MEX.tokenA())).balanceOf(deployer);
        vm.startBroadcast(pk);
        IERC20(yubii).approve(address(USA_MEX), type(uint256).max);
        USA_MEX.buy{value: 0.02 ether}(true, 0);
        vm.stopBroadcast();
        uint256 received = IERC20(address(USA_MEX.tokenA())).balanceOf(deployer) - tokensBefore;
        console2.log("\n[3] 0.02 ETH buy succeeded");
        console2.log("    yUSA received:", received);
    }

    // ── testReduceTax ─────────────────────────────────────────────────────────
    // forge script script/Interact.s.sol --sig "testReduceTax()" \
    //   --rpc-url $SEPOLIA_RPC --broadcast

    function testReduceTax() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address yubii   = 0xacB4474196bDA1d8ba0ECc7B3B72178C09cd2F21;
        address mkt     = 0xfCFA09B1Bc297F7B61401FbfBf76865fE9b12CB0;

        console2.log("=== testReduceTax: USA vs MEX ===");
        console2.log("buyTaxBps  :", USA_MEX.buyTaxBps());
        console2.log("sellTaxBps :", USA_MEX.sellTaxBps());

        // 1. reduceTax(300, 300) -> 3%
        vm.startBroadcast(pk);
        USA_MEX.reduceTax(300, 300);
        vm.stopBroadcast();
        console2.log("\n[1] reduceTax(300, 300) called");
        console2.log("    buyTaxBps  :", USA_MEX.buyTaxBps());
        console2.log("    sellTaxBps :", USA_MEX.sellTaxBps());

        // 2. Buy 0.005 ETH and check marketing wallet tax (should be 3% = 0.00015 ETH)
        uint256 mktBefore1 = mkt.balance;
        vm.startBroadcast(pk);
        IERC20(yubii).approve(address(USA_MEX), type(uint256).max);
        USA_MEX.buy{value: 0.005 ether}(true, 0);
        vm.stopBroadcast();
        uint256 taxAt3pct = mkt.balance - mktBefore1;
        console2.log("\n[2] Buy 0.005 ETH at 3% tax");
        console2.log("    Marketing received:", taxAt3pct);
        console2.log("    Expected ~150000000000000 (0.00015 ETH)");

        // 3. removeTax() -> 0%
        vm.startBroadcast(pk);
        USA_MEX.removeTax();
        vm.stopBroadcast();
        console2.log("\n[3] removeTax() called");
        console2.log("    buyTaxBps  :", USA_MEX.buyTaxBps());
        console2.log("    sellTaxBps :", USA_MEX.sellTaxBps());

        // 4. Buy 0.005 ETH again and verify zero tax
        uint256 mktBefore2 = mkt.balance;
        vm.startBroadcast(pk);
        IERC20(yubii).approve(address(USA_MEX), type(uint256).max);
        USA_MEX.buy{value: 0.005 ether}(true, 0);
        vm.stopBroadcast();
        uint256 taxAt0pct = mkt.balance - mktBefore2;
        console2.log("\n[4] Buy 0.005 ETH at 0% tax");
        console2.log("    Marketing received:", taxAt0pct);
        console2.log("    Tax zeroed        :", taxAt0pct == 0);

        console2.log("\nDeployer ETH remaining:", deployer.balance);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _ensureYubiiApproved(uint256 pk, address trader) internal {
        uint256 fee = (BUY_ETH * 30) / 10000;
        require(IERC20(YUBII_TOKEN).balanceOf(trader) >= fee, "Insufficient YUBII for fee");
        if (IERC20(YUBII_TOKEN).allowance(trader, address(MARKET)) < fee) {
            vm.startBroadcast(pk);
            IERC20(YUBII_TOKEN).approve(address(MARKET), type(uint256).max);
            vm.stopBroadcast();
        }
    }
}
