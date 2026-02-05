// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {GrimSwapZK} from "../src/zk/GrimSwapZK.sol";
import {GrimPool} from "../src/zk/GrimPool.sol";
import {GrimSwapRouter, IPoolSwapTest} from "../src/zk/GrimSwapRouter.sol";
import {IGroth16Verifier} from "../src/zk/interfaces/IGroth16Verifier.sol";
import {IGrimPool} from "../src/zk/interfaces/IGrimPool.sol";

/// @title DeployV3
/// @notice Deploy GrimSwap V3: GrimPool + GrimSwapZK (dual-mode) + GrimSwapRouter
contract DeployV3 is Script {
    // CREATE2 Deployer Proxy (standard address on most chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Unichain Sepolia addresses
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant GROTH16_VERIFIER = 0xF7D14b744935cE34a210D7513471a8E6d6e696a0;
    address constant POOL_SWAP_TEST = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;

    // Required hook flags for GrimSwapZK:
    // - beforeSwap (bit 7): 0x80
    // - afterSwap (bit 6): 0x40
    // - afterSwapReturnDelta (bit 2): 0x04
    // Combined: 0xC4
    uint160 constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("  GrimSwap V3 Deployment");
        console.log("  Dual-Mode Hook + Router");
        console.log("========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new GrimPool V3
        console.log("[1/5] Deploying GrimPool V3...");
        GrimPool grimPool = new GrimPool();
        console.log("  GrimPool V3:", address(grimPool));

        vm.stopBroadcast();

        // 2. Mine for valid hook address (needs GrimPool address for constructor)
        console.log("[2/5] Mining for valid hook address (flags: 0xC4)...");
        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            IGroth16Verifier(GROTH16_VERIFIER),
            IGrimPool(address(grimPool))
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            REQUIRED_FLAGS,
            type(GrimSwapZK).creationCode,
            constructorArgs
        );
        console.log("  Hook address:", hookAddress);
        console.log("  Salt:", vm.toString(salt));

        // 3. Deploy GrimSwapZK V3 via CREATE2
        console.log("[3/5] Deploying GrimSwapZK V3 (dual-mode) via CREATE2...");
        bytes memory bytecode = abi.encodePacked(type(GrimSwapZK).creationCode, constructorArgs);

        vm.startBroadcast(deployerPrivateKey);

        (bool success, ) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, bytecode));
        require(success, "CREATE2 deployment failed");
        require(hookAddress.code.length > 0, "No code at expected hook address");
        console.log("  GrimSwapZK V3:", hookAddress);

        // 4. Deploy GrimSwapRouter
        console.log("[4/5] Deploying GrimSwapRouter...");
        GrimSwapRouter router = new GrimSwapRouter(
            IGrimPool(address(grimPool)),
            IPoolSwapTest(POOL_SWAP_TEST)
        );
        console.log("  GrimSwapRouter:", address(router));

        // 5. Configure permissions
        console.log("[5/5] Configuring permissions...");

        // Set GrimSwapZK as the authorized hook on GrimPool
        grimPool.setGrimSwapZK(hookAddress);
        console.log("  GrimPool.grimSwapZK =", hookAddress);

        // Authorize the router to release ETH from GrimPool
        grimPool.setAuthorizedRouter(address(router), true);
        console.log("  GrimPool.authorizedRouters[router] = true");

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log("  DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("GrimPool V3:      ", address(grimPool));
        console.log("GrimSwapZK V3:    ", hookAddress);
        console.log("GrimSwapRouter:   ", address(router));
        console.log("Groth16Verifier:  ", GROTH16_VERIFIER);
        console.log("PoolManager:      ", POOL_MANAGER);
        console.log("PoolSwapTest:     ", POOL_SWAP_TEST);
        console.log("");
        console.log("Features:");
        console.log("  - Dual-mode hook (regular + private swaps)");
        console.log("  - GrimSwapRouter (atomic ETH release + swap)");
        console.log("  - releaseForSwap (authorized router ETH release)");
        console.log("");
        console.log("NEXT: Initialize pool + add liquidity");
        console.log("========================================");
    }
}
