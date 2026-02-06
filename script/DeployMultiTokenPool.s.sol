// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {GrimPoolMultiToken} from "../src/zk/GrimPoolMultiToken.sol";

contract DeployMultiTokenPool is Script {
    // Existing contracts on Unichain Sepolia
    address constant GRIM_SWAP_ZK = 0x3bee7D1A5914d1ccD34D2a2d00C359D0746400C4;
    address constant GRIM_SWAP_ROUTER = 0xC13a6a504da21aD23c748f08d3E991621D42DA4F;

    // USDC on Unichain Sepolia
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy GrimPoolMultiToken
        GrimPoolMultiToken pool = new GrimPoolMultiToken();
        console.log("GrimPoolMultiToken deployed at:", address(pool));

        // Configure the pool
        pool.setGrimSwapZK(GRIM_SWAP_ZK);
        console.log("Set GrimSwapZK to:", GRIM_SWAP_ZK);

        pool.setAuthorizedRouter(GRIM_SWAP_ROUTER, true);
        console.log("Authorized router:", GRIM_SWAP_ROUTER);

        // Whitelist USDC for deposits
        pool.setAllowedToken(USDC, true);
        console.log("Whitelisted USDC:", USDC);

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("GrimPoolMultiToken:", address(pool));
        console.log("Owner:", pool.owner());
    }
}
