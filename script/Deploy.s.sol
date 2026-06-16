// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {YubiiToken} from "../src/YubiiToken.sol";
import {YubiiFactory} from "../src/YubiiFactory.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Multi-network deploy — 4 FIFA World Cup 2026 matches
// Supports Sepolia (11155111) and Mainnet (1); reverts on any other chain.
//
// Required .env variables:
//   PRIVATE_KEY          — deployer key for Sepolia
//   MAINNET_PRIVATE_KEY  — deployer key for Mainnet (single wallet: owner + marketing + fee recipient)
//
// Sepolia:
//   forge script script/Deploy.s.sol \
//     --rpc-url $SEPOLIA_RPC \
//     --broadcast --verify --slow -vvvv
//
// Mainnet:
//   forge script script/Deploy.s.sol \
//     --rpc-url $MAINNET_RPC \
//     --broadcast --verify --slow -vvvv
//
// Estimated cost: 4 matches x 0.02 ETH = 0.08 ETH + gas
// ─────────────────────────────────────────────────────────────────────────────

contract Deploy is Script {
    uint256 constant LIQUIDITY_PER_MATCH = 0.02 ether; // 0.01 ETH per pool x 2

    // ── Chain IDs ─────────────────────────────────────────────────────────────
    uint256 constant CHAIN_MAINNET = 1;
    uint256 constant CHAIN_SEPOLIA = 11155111;

    // ── Mainnet addresses ─────────────────────────────────────────────────────
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant MAINNET_UMA_OO_V3    = 0x88Ad27C41AD06f01153E7Cd9b10cBEdF4616f4d5;

    // ── Sepolia addresses ─────────────────────────────────────────────────────
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant SEPOLIA_UMA_OO_V3    = 0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944;

    // ── Mainnet: real World Cup 2026 kickoff timestamps (UTC) ────────────────
    uint256 constant KICKOFF_USA_MEX = 1750622400; // 2026-06-22 20:00 UTC
    uint256 constant KICKOFF_ENG_FRA = 1750968000; // 2026-06-26 20:00 UTC
    uint256 constant KICKOFF_BRA_ARG = 1751227200; // 2026-06-29 20:00 UTC
    uint256 constant KICKOFF_GER_ESP = 1751486400; // 2026-07-02 20:00 UTC

    function run() external {
        uint256 chainId = block.chainid;

        address poolManager;
        address umaOov3;
        string memory networkName;

        if (chainId == CHAIN_MAINNET) {
            poolManager = MAINNET_POOL_MANAGER;
            umaOov3     = MAINNET_UMA_OO_V3;
            networkName = "Ethereum Mainnet";
        } else if (chainId == CHAIN_SEPOLIA) {
            poolManager = SEPOLIA_POOL_MANAGER;
            umaOov3     = SEPOLIA_UMA_OO_V3;
            networkName = "Sepolia";
        } else {
            revert("Unsupported chain: use mainnet (1) or Sepolia (11155111)");
        }

        uint256 deployerKey = chainId == CHAIN_MAINNET
            ? vm.envUint("MAINNET_PRIVATE_KEY")
            : vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Sepolia: kickoffs relative to deployment for easy testing
        // Mainnet: real World Cup timestamps
        uint256 k1 = chainId == CHAIN_SEPOLIA ? block.timestamp + 1 days : KICKOFF_USA_MEX;
        uint256 k2 = chainId == CHAIN_SEPOLIA ? block.timestamp + 3 days : KICKOFF_ENG_FRA;
        uint256 k3 = chainId == CHAIN_SEPOLIA ? block.timestamp + 5 days : KICKOFF_BRA_ARG;
        uint256 k4 = chainId == CHAIN_SEPOLIA ? block.timestamp + 7 days : KICKOFF_GER_ESP;

        console2.log("=== YUBII CUP - DEPLOY ===");
        console2.log("Network     :", networkName);
        console2.log("Chain ID    :", chainId);
        console2.log("Deployer    :", deployer);
        console2.log("Balance     :", deployer.balance);
        console2.log("PoolManager :", poolManager);
        console2.log("UMA OO v3   :", umaOov3);
        console2.log("ETH needed  : 0.08 ETH + gas");

        require(deployer.balance >= 0.08 ether, "Insufficient ETH: need at least 0.08 ETH");

        vm.startBroadcast(deployerKey);

        // 1. Deploy governance token
        YubiiToken yubii = new YubiiToken(deployer);
        console2.log("\nYubiiToken  :", address(yubii));

        // 2. Deploy factory — single-wallet model: deployer is owner, fee recipient, and marketing wallet
        YubiiFactory factory = new YubiiFactory(
            poolManager,
            address(yubii),
            umaOov3,
            deployer,   // fee recipient
            deployer,   // owner
            deployer    // marketingWallet
        );
        console2.log("YubiiFactory:", address(factory));

        // 3. Create matches (extracted to avoid stack-too-deep)
        _createMatches(factory, k1, k2, k3, k4);

        vm.stopBroadcast();

        console2.log("\n=== DEPLOYMENT SUMMARY ===");
        console2.log("Network     :", networkName);
        console2.log("YubiiToken  :", address(yubii));
        console2.log("YubiiFactory:", address(factory));
        console2.log("PoolManager :", poolManager);
        console2.log("UMA OO v3   :", umaOov3);
        console2.log("==========================");
    }

    function _createMatches(YubiiFactory factory, uint256 k1, uint256 k2, uint256 k3, uint256 k4) internal {
        console2.log("\nMatch 1 (USA vs MEX) :", factory.createMatch{value: LIQUIDITY_PER_MATCH}("USA", "MEX", k1, 1));
        console2.log("  Kickoff             :", k1);

        console2.log("Match 2 (ENG vs FRA) :", factory.createMatch{value: LIQUIDITY_PER_MATCH}("England", "France", k2, 1));
        console2.log("  Kickoff             :", k2);

        console2.log("Match 3 (BRA vs ARG) :", factory.createMatch{value: LIQUIDITY_PER_MATCH}("Brazil", "Argentina", k3, 1));
        console2.log("  Kickoff             :", k3);

        console2.log("Match 4 (GER vs ESP) :", factory.createMatch{value: LIQUIDITY_PER_MATCH}("Germany", "Spain", k4, 1));
        console2.log("  Kickoff             :", k4);
    }
}
