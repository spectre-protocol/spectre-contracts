// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {GrimSwapZK} from "../src/zk/GrimSwapZK.sol";
import {GrimPoolMultiToken} from "../src/zk/GrimPoolMultiToken.sol";
import {IGroth16Verifier} from "../src/zk/interfaces/IGroth16Verifier.sol";
import {IGrimPool} from "../src/zk/interfaces/IGrimPool.sol";

/// @title DeployHookMultiToken
/// @notice Deploy GrimSwapZK hook pointing to GrimPoolMultiToken using CREATE2 deployer
contract DeployHookMultiToken is Script {
    // Unichain Sepolia
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant GROTH16_VERIFIER = 0xF7D14b744935cE34a210D7513471a8E6d6e696a0;
    address payable constant GRIM_POOL_MULTI_TOKEN = payable(0x6777cfe2A72669dA5a8087181e42CA3dB29e7710);

    // Deterministic CREATE2 deployer
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Required hook flags: BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA = 0xC4
    uint160 constant REQUIRED_FLAGS = 0xC4;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Mining Hook Address ===");

        // Get init code
        bytes memory creationCode = type(GrimSwapZK).creationCode;
        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            IGroth16Verifier(GROTH16_VERIFIER),
            IGrimPool(GRIM_POOL_MULTI_TOKEN)
        );
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);

        // Mine salt using CREATE2 deployer address
        bytes32 salt;
        address payable hookAddress;
        bool found = false;

        for (uint256 i = 0; i < 1000000; i++) {
            salt = bytes32(i);
            hookAddress = payable(computeCreate2Address(CREATE2_DEPLOYER, salt, initCodeHash));

            if (uint160(address(hookAddress)) & 0x3FFF == REQUIRED_FLAGS) {
                found = true;
                console.log("Found salt:", i);
                console.log("Hook address:", hookAddress);
                break;
            }
        }

        require(found, "Could not find valid salt");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy via CREATE2 deployer by sending tx with salt + initCode
        bytes memory deployData = abi.encodePacked(salt, initCode);
        (bool success, ) = CREATE2_DEPLOYER.call(deployData);
        require(success, "CREATE2 deployment failed");

        GrimSwapZK hook = GrimSwapZK(hookAddress);
        console.log("Hook deployed at:", address(hook));

        // Authorize hook in GrimPoolMultiToken
        GrimPoolMultiToken(GRIM_POOL_MULTI_TOKEN).setGrimSwapZK(address(hook));
        console.log("Hook authorized in GrimPoolMultiToken");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Hook:", address(hook));
    }

    function computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            initCodeHash
        )))));
    }
}
