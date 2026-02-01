// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {SpectreHook} from "../src/SpectreHook.sol";
import {RingVerifier} from "../src/RingVerifier.sol";
import {StealthAddressRegistry} from "../src/StealthAddressRegistry.sol";
import {ERC5564Announcer} from "../src/ERC5564Announcer.sol";

/// @title DeploySpectre
/// @notice Deployment script for Spectre Protocol contracts
contract DeploySpectre is Script {
    // Uniswap v4 PoolManager addresses
    // Unichain Sepolia: TBD (check Uniswap docs)
    // Unichain Mainnet: TBD (check Uniswap docs)
    address constant POOL_MANAGER_SEPOLIA = address(0); // TODO: Update with actual address
    address constant POOL_MANAGER_MAINNET = address(0); // TODO: Update with actual address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Spectre Protocol...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy supporting contracts
        RingVerifier ringVerifier = new RingVerifier();
        console.log("RingVerifier deployed at:", address(ringVerifier));

        StealthAddressRegistry stealthRegistry = new StealthAddressRegistry();
        console.log("StealthAddressRegistry deployed at:", address(stealthRegistry));

        ERC5564Announcer announcer = new ERC5564Announcer();
        console.log("ERC5564Announcer deployed at:", address(announcer));

        // 2. Determine PoolManager address based on chain
        address poolManager;
        if (block.chainid == 1301) {
            // Unichain Sepolia
            poolManager = POOL_MANAGER_SEPOLIA;
        } else if (block.chainid == 130) {
            // Unichain Mainnet
            poolManager = POOL_MANAGER_MAINNET;
        } else {
            revert("Unsupported chain");
        }

        require(poolManager != address(0), "PoolManager address not set");

        // 3. Compute hook address with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Find salt for CREATE2 that results in address with correct flags
        bytes memory creationCode = abi.encodePacked(
            type(SpectreHook).creationCode,
            abi.encode(IPoolManager(poolManager), ringVerifier, stealthRegistry, announcer)
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(deployer, flags, creationCode, type(SpectreHook).creationCode);
        console.log("Target hook address:", hookAddress);

        // 4. Deploy SpectreHook at the computed address
        SpectreHook hook = new SpectreHook{salt: salt}(
            IPoolManager(poolManager),
            ringVerifier,
            stealthRegistry,
            announcer
        );

        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("SpectreHook deployed at:", address(hook));

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("RingVerifier:", address(ringVerifier));
        console.log("StealthAddressRegistry:", address(stealthRegistry));
        console.log("ERC5564Announcer:", address(announcer));
        console.log("SpectreHook:", address(hook));
        console.log("========================\n");
    }
}
