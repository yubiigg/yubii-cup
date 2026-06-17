// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {YubiiFactory} from "../src/YubiiFactory.sol";
import {MatchMarket} from "../src/MatchMarket.sol";

// ─────────────────────────────────────────────────────────────────────────────
// BatchDeploy — reads matches.json and calls factory.createMatch() for each
// upcoming fixture not already deployed on-chain.
//
// Prerequisite: generate matches.json first
//   node scripts/generate-matches-json.mjs   (or: npm run generate-matches)
//
// Dry-run (simulation, no broadcast):
//   forge script script/BatchDeploy.s.sol \
//     --rpc-url $SEPOLIA_RPC -vvvv
//
// Broadcast:
//   forge script script/BatchDeploy.s.sol \
//     --rpc-url $SEPOLIA_RPC --broadcast --slow -vvvv
//
// Required env vars:
//   PRIVATE_KEY      — deployer/factory-owner key
//   YUBII_FACTORY    — (optional) factory address; defaults to Sepolia/Mainnet constants
// ─────────────────────────────────────────────────────────────────────────────

contract BatchDeploy is Script {

    // Struct field order MUST be alphabetical for vm.parseJson struct decode
    // (Foundry sorts JSON object keys alphabetically before ABI-encoding)
    struct Match {
        uint256 feeProfile; // f
        uint256 kickoff;    // k
        string  teamA;      // t + A
        string  teamB;      // t + B
    }

    // ── Chain-aware factory defaults ──────────────────────────────────────────
    uint256 constant CHAIN_MAINNET = 1;
    uint256 constant CHAIN_SEPOLIA = 11155111;

    address constant SEPOLIA_FACTORY = 0x38Df9f316abb91163Fbfd6eaB048DC357BA384A8;
    address constant MAINNET_FACTORY = address(0); // set after mainnet deploy

    uint256 constant LIQUIDITY_PER_MATCH = 0.02 ether;
    uint256 constant SAFETY_BUFFER       = 1 hours;

    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Chain-aware factory address — env var takes precedence
        address defaultFactory = block.chainid == CHAIN_MAINNET
            ? MAINNET_FACTORY
            : SEPOLIA_FACTORY;
        YubiiFactory factory = YubiiFactory(
            vm.envOr("YUBII_FACTORY", defaultFactory)
        );

        require(address(factory) != address(0), "YUBII_FACTORY not set and no default for this chain");

        // ── Parse matches.json ────────────────────────────────────────────────
        // JSON keys must be alphabetical (generate-matches-json.mjs guarantees this):
        // feeProfile, kickoff, teamA, teamB
        string memory json  = vm.readFile("matches.json");
        bytes  memory raw   = vm.parseJson(json);
        Match[] memory matches = abi.decode(raw, (Match[]));

        console2.log("=== BATCH DEPLOY ===");
        console2.log("Network    :", block.chainid == CHAIN_MAINNET ? "Mainnet" : "Sepolia");
        console2.log("Factory    :", address(factory));
        console2.log("Deployer   :", deployer);
        console2.log("ETH balance:", deployer.balance);
        console2.log(string.concat("Matches in JSON : ", vm.toString(matches.length)));

        require(matches.length > 0, "matches.json is empty -- run generate-matches-json.mjs first");

        // ── Snapshot existing markets to detect duplicates ────────────────────
        uint256 existingCount = factory.marketCount();
        console2.log(string.concat("Existing markets: ", vm.toString(existingCount)));

        // Track teams deployed in this batch (can't reread live state mid-broadcast)
        string[] memory batchA = new string[](matches.length);
        string[] memory batchB = new string[](matches.length);
        uint256 batchSize = 0;

        uint256 created      = 0;
        uint256 skipTooSoon  = 0;
        uint256 skipDuplicate = 0;

        vm.startBroadcast(deployerKey);

        for (uint256 i = 0; i < matches.length; i++) {
            Match memory m = matches[i];

            // ── Guard: kickoff must be at least SAFETY_BUFFER away ────────────
            if (m.kickoff < block.timestamp + SAFETY_BUFFER) {
                console2.log(string.concat(
                    "[SKIP:soon] ", m.teamA, " vs ", m.teamB,
                    " | kickoff=", vm.toString(m.kickoff)
                ));
                skipTooSoon++;
                continue;
            }

            // ── Guard: not already on-chain ───────────────────────────────────
            if (_isOnChain(factory, existingCount, m.teamA, m.teamB)) {
                console2.log(string.concat(
                    "[SKIP:dup-chain] ", m.teamA, " vs ", m.teamB
                ));
                skipDuplicate++;
                continue;
            }

            // ── Guard: not already in this batch ──────────────────────────────
            if (_isInBatch(batchA, batchB, batchSize, m.teamA, m.teamB)) {
                console2.log(string.concat(
                    "[SKIP:dup-batch] ", m.teamA, " vs ", m.teamB
                ));
                skipDuplicate++;
                continue;
            }

            // ── Deploy ────────────────────────────────────────────────────────
            address marketAddr = factory.createMatch{value: LIQUIDITY_PER_MATCH}(
                m.teamA,
                m.teamB,
                m.kickoff,
                uint8(m.feeProfile)
            );

            batchA[batchSize] = m.teamA;
            batchB[batchSize] = m.teamB;
            batchSize++;
            created++;

            console2.log(string.concat(
                "[CREATED] ", m.teamA, " vs ", m.teamB,
                " @ ", vm.toString(marketAddr)
            ));
            console2.log(string.concat(
                "  kickoff=", vm.toString(m.kickoff),
                "  feeProfile=", vm.toString(m.feeProfile),
                "  liquidity=0.02 ETH"
            ));
        }

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console2.log("\n=== BATCH DEPLOY SUMMARY ===");
        console2.log(string.concat("Created           : ", vm.toString(created)));
        console2.log(string.concat("Skipped (too soon): ", vm.toString(skipTooSoon)));
        console2.log(string.concat("Skipped (duplicate): ", vm.toString(skipDuplicate)));
        console2.log(string.concat(
            "ETH spent         : ",
            vm.toString(created * LIQUIDITY_PER_MATCH / 1e15),
            " finney (", vm.toString(created), " x 0.02 ETH)"
        ));
        console2.log(string.concat("Deployer ETH left : ", vm.toString(deployer.balance)));
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _isOnChain(
        YubiiFactory factory,
        uint256 count,
        string memory teamA,
        string memory teamB
    ) internal view returns (bool) {
        bytes32 hashA = keccak256(bytes(teamA));
        bytes32 hashB = keccak256(bytes(teamB));
        for (uint256 i = 0; i < count; i++) {
            MatchMarket m = MatchMarket(payable(factory.markets(i)));
            if (
                keccak256(bytes(m.teamA())) == hashA &&
                keccak256(bytes(m.teamB())) == hashB
            ) return true;
        }
        return false;
    }

    function _isInBatch(
        string[] memory batchA,
        string[] memory batchB,
        uint256 size,
        string memory teamA,
        string memory teamB
    ) internal pure returns (bool) {
        bytes32 hashA = keccak256(bytes(teamA));
        bytes32 hashB = keccak256(bytes(teamB));
        for (uint256 i = 0; i < size; i++) {
            if (
                keccak256(bytes(batchA[i])) == hashA &&
                keccak256(bytes(batchB[i])) == hashB
            ) return true;
        }
        return false;
    }
}
