// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {GrimSwapZK} from "../src/zk/GrimSwapZK.sol";
import {GrimPool} from "../src/zk/GrimPool.sol";
import {Groth16Verifier} from "../src/zk/Groth16Verifier.sol";
import {IGroth16Verifier} from "../src/zk/interfaces/IGroth16Verifier.sol";
import {IGrimPool} from "../src/zk/interfaces/IGrimPool.sol";

/// @title DeployGrimSwapZK
/// @notice Deploy GrimSwapZK hook using pre-mined salt
contract DeployGrimSwapZK is Script {
    // Unichain Sepolia PoolManager
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    // Deployed contracts (final deployment with fixed signal indices)
    address constant GRIM_POOL = 0xad079eAC28499c4eeA5C02D2DE1C81E56b9AA090;
    address constant GROTH16_VERIFIER = 0xF7D14b744935cE34a210D7513471a8E6d6e696a0;

    // Pre-mined salt (from hook-mine-result.json)
    // Using CREATE2 deployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C
    bytes32 constant MINED_SALT = bytes32(uint256(15507));

    // Expected hook address
    address constant EXPECTED_HOOK = 0x95ED348fCC232FB040e46c77C60308517e4BC0C4;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying GrimSwapZK Hook ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("PoolManager:", POOL_MANAGER);
        console.log("GrimPool:", GRIM_POOL);
        console.log("Groth16Verifier:", GROTH16_VERIFIER);
        console.log("Expected Hook:", EXPECTED_HOOK);
        console.log("Salt:", uint256(MINED_SALT));

        vm.startBroadcast(deployerPrivateKey);

        // Deploy GrimSwapZK with pre-mined salt
        GrimSwapZK hook = new GrimSwapZK{salt: MINED_SALT}(
            IPoolManager(POOL_MANAGER),
            IGroth16Verifier(GROTH16_VERIFIER),
            IGrimPool(GRIM_POOL)
        );

        console.log("GrimSwapZK deployed at:", address(hook));

        // Verify address matches expected
        require(address(hook) == EXPECTED_HOOK, "Hook address mismatch!");

        // Verify hook flags
        uint160 hookFlags = uint160(address(hook)) & 0x3FFF;
        console.log("Hook flags:", uint256(hookFlags));
        require(hookFlags == 0xC4, "Invalid hook flags!");

        // Authorize GrimSwapZK in GrimPool
        GrimPool(GRIM_POOL).setGrimSwapZK(address(hook));
        console.log("GrimSwapZK authorized in GrimPool");

        vm.stopBroadcast();

        console.log("");
        console.log("========== Deployment Summary ==========");
        console.log("GrimSwapZK Hook:", address(hook));
        console.log("  - beforeSwap: true");
        console.log("  - afterSwap: true");
        console.log("  - afterSwapReturnDelta: true");
        console.log("=========================================");
    }
}
