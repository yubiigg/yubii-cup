// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MatchMarket} from "../src/MatchMarket.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Live interaction script — Sepolia: England vs France
//
// Usage (each step is a separate broadcast):
//
//   # Show market state (no broadcast)
//   forge script script/Interact.s.sol --rpc-url $SEPOLIA_RPC
//
//   # 1. Buy WENG tokens with 0.005 ETH
//   forge script script/Interact.s.sol --sig "buyWENG()" \
//     --rpc-url $SEPOLIA_RPC --broadcast
//
//   # 2. Buy WFRA tokens with 0.005 ETH
//   forge script script/Interact.s.sol --sig "buyWFRA()" \
//     --rpc-url $SEPOLIA_RPC --broadcast
//
//   # 3. Request settlement (run AFTER kickoff)
//   forge script script/Interact.s.sol --sig "requestSettlementENG()" \
//     --rpc-url $SEPOLIA_RPC --broadcast
//   #  Then wait ~2h for UMA liveness, then anyone calls:
//   #  cast send <ORACLE> "settleAssertion(bytes32)" <assertionId> --rpc-url $SEPOLIA_RPC
//
//   # 4. Redeem WENG for ETH (after settlement resolves)
//   forge script script/Interact.s.sol --sig "redeemWENG()" \
//     --rpc-url $SEPOLIA_RPC --broadcast
//
// Required .env variables:
//   PRIVATE_KEY   — deployer / trader private key
//   SEPOLIA_RPC   — Sepolia RPC endpoint
// ─────────────────────────────────────────────────────────────────────────────

contract Interact is Script {
    // ── deployed addresses ────────────────────────────────────────────────────
    MatchMarket constant MARKET = MatchMarket(payable(0xEE41eFB4aE281e47E18f880A4455948482803F54));
    address     constant YUBII  = 0x3524cAcC5e30073C3F941Dc135c89c35Cd182Ca9;

    uint256 constant BUY_ETH = 0.005 ether;

    // ── token addresses resolved from market at runtime ───────────────────────
    function _weng() internal view returns (address) { return address(MARKET.tokenA()); }
    function _wfra() internal view returns (address) { return address(MARKET.tokenB()); }
    function _oracle() internal view returns (address) { return address(MARKET.oracle()); }
    function _kickoff() internal view returns (uint256) { return MARKET.kickoffTime(); }

    // ─────────────────────────────────────────────────────────────────────────
    // Default: show market state
    // ─────────────────────────────────────────────────────────────────────────

    function run() external view {
        _printState();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 1 — Buy $WENG (bet on England)
    // ─────────────────────────────────────────────────────────────────────────

    function buyWENG() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        _requireNotSettled();
        _ensureYubiiApproved(pk, trader);

        console2.log("Buying WENG with", BUY_ETH, "ETH...");
        uint256 before = IERC20(_weng()).balanceOf(trader);

        vm.startBroadcast(pk);
        MARKET.buy{value: BUY_ETH}(true, 0);
        vm.stopBroadcast();

        console2.log("WENG received :", IERC20(_weng()).balanceOf(trader) - before);
        console2.log("WENG balance  :", IERC20(_weng()).balanceOf(trader));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 2 — Buy $WFRA (bet on France)
    // ─────────────────────────────────────────────────────────────────────────

    function buyWFRA() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        _requireNotSettled();
        _ensureYubiiApproved(pk, trader);

        console2.log("Buying WFRA with", BUY_ETH, "ETH...");
        uint256 before = IERC20(_wfra()).balanceOf(trader);

        vm.startBroadcast(pk);
        MARKET.buy{value: BUY_ETH}(false, 0);
        vm.stopBroadcast();

        console2.log("WFRA received :", IERC20(_wfra()).balanceOf(trader) - before);
        console2.log("WFRA balance  :", IERC20(_wfra()).balanceOf(trader));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 3 — Request settlement: England wins
    //   Requires block.timestamp >= kickoffTime
    //   After this: wait ~2h for UMA liveness, then settle the assertion
    // ─────────────────────────────────────────────────────────────────────────

    function requestSettlementENG() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address asserter = vm.addr(pk);
        uint256 kickoff = _kickoff();

        require(!MARKET.settled(), "Already settled");
        require(block.timestamp >= kickoff, string.concat(
            "Too early - kickoff in ",
            _secondsToStr(kickoff - block.timestamp)
        ));
        require(MARKET.pendingAssertionId() == bytes32(0), "Assertion already pending");

        console2.log("Requesting settlement: England wins...");
        console2.log("Asserter:", asserter);

        vm.startBroadcast(pk);
        bytes32 assertionId = MARKET.requestSettlement(
            1,          // 1 = teamA = England
            asserter,
            address(0), // no bond
            0
        );
        vm.stopBroadcast();

        console2.log("Assertion ID :", vm.toString(assertionId));
        console2.log("Liveness     : 7200s (~2 hours)");
        console2.log("");
        console2.log("After liveness expires, settle with:");
        console2.log("  cast send <ORACLE> \"settleAssertion(bytes32)\" <assertionId>");
        console2.log("  ORACLE      :", _oracle());
        console2.log("  assertionId :", vm.toString(assertionId));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 4 — Redeem all WENG tokens for ETH
    // ─────────────────────────────────────────────────────────────────────────

    function redeemWENG() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        require(MARKET.settled(), "Market not settled yet");
        require(MARKET.winner() == 1, "England did not win; only teamA (WENG) redeems");

        uint256 wengBalance = IERC20(_weng()).balanceOf(trader);
        require(wengBalance > 0, "No WENG to redeem");

        uint256 expectedEth = (wengBalance * MARKET.totalSettledETH()) / MARKET.settledWinnerSupply();
        console2.log("Redeeming WENG:", wengBalance);
        console2.log("Expected ETH  :", expectedEth);

        uint256 ethBefore = trader.balance;

        vm.startBroadcast(pk);
        IERC20(_weng()).approve(address(MARKET), wengBalance);
        MARKET.redeem(wengBalance);
        vm.stopBroadcast();

        console2.log("ETH received  :", trader.balance - ethBefore);
        console2.log("WENG remaining:", IERC20(_weng()).balanceOf(trader));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _printState() internal view {
        uint256 kickoff = _kickoff();
        console2.log("=== YUBII CUP: ENG vs FRA ===");
        console2.log("Market    :", address(MARKET));
        console2.log("WENG      :", _weng());
        console2.log("WFRA      :", _wfra());
        console2.log("YUBII     :", YUBII);
        console2.log("Kickoff   :", kickoff);
        console2.log("Settled   :", MARKET.settled());
        console2.log("LiquidityA:", MARKET.liquidityA());
        console2.log("LiquidityB:", MARKET.liquidityB());

        if (block.timestamp < kickoff) {
            console2.log("Time to kickoff:", _secondsToStr(kickoff - block.timestamp));
        } else {
            console2.log("Kickoff passed. Ready for settlement.");
        }

        if (MARKET.settled()) {
            console2.log("Winner    :", MARKET.winner() == 1 ? "ENG (teamA)" : "FRA (teamB)");
            console2.log("Pool ETH  :", MARKET.totalSettledETH());
        }

        if (MARKET.pendingAssertionId() != bytes32(0)) {
            console2.log("Pending assertion:", vm.toString(MARKET.pendingAssertionId()));
        }
    }

    function _requireNotSettled() internal view {
        require(!MARKET.settled(), "Market already settled");
    }

    function _ensureYubiiApproved(uint256 pk, address trader) internal {
        uint256 allowance = IERC20(YUBII).allowance(trader, address(MARKET));
        uint256 balance   = IERC20(YUBII).balanceOf(trader);
        uint256 fee       = (BUY_ETH * 30) / 10000;

        console2.log("YUBII balance :", balance);
        console2.log("YUBII fee     :", fee);
        require(balance >= fee, "Insufficient YUBII for protocol fee");

        if (allowance < fee) {
            console2.log("Approving YUBII...");
            vm.startBroadcast(pk);
            IERC20(YUBII).approve(address(MARKET), type(uint256).max);
            vm.stopBroadcast();
        }
    }

    function _secondsToStr(uint256 s) internal pure returns (string memory) {
        uint256 d = s / 86400;
        uint256 h = (s % 86400) / 3600;
        uint256 m = (s % 3600) / 60;
        return string.concat(
            _uintStr(d), "d ", _uintStr(h), "h ", _uintStr(m), "m"
        );
    }

    function _uintStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v; uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { b[--len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
