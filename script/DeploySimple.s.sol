// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {RingVerifier} from "../src/RingVerifier.sol";
import {StealthAddressRegistry} from "../src/StealthAddressRegistry.sol";
import {ERC5564Announcer} from "../src/ERC5564Announcer.sol";

/// @title DeploySimple
/// @notice Deploy supporting contracts without the hook (for testing)
contract DeploySimple is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Spectre Protocol (Simple)...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy supporting contracts
        RingVerifier ringVerifier = new RingVerifier();
        console.log("RingVerifier deployed at:", address(ringVerifier));

        StealthAddressRegistry stealthRegistry = new StealthAddressRegistry();
        console.log("StealthAddressRegistry deployed at:", address(stealthRegistry));

        ERC5564Announcer announcer = new ERC5564Announcer();
        console.log("ERC5564Announcer deployed at:", address(announcer));

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("RingVerifier:", address(ringVerifier));
        console.log("StealthAddressRegistry:", address(stealthRegistry));
        console.log("ERC5564Announcer:", address(announcer));
        console.log("========================\n");
    }
}
