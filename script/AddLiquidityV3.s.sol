// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolTestHelper} from "../src/test/PoolTestHelper.sol";

/// @title AddLiquidityV3
/// @notice Add liquidity to the V3 pool (dual-mode hook)
contract AddLiquidityV3 is Script {
    // Unichain Sepolia contracts
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant GRIM_SWAP_ZK_V3 = 0xeB72E2495640a4B83EBfc4618FD91cc9beB640c4;

    // Existing test tokens
    address constant TOKEN_A = 0x48bA64b5312AFDfE4Fc96d8F03010A0a86e17963;
    address constant TOKEN_B = 0x96aC37889DfDcd4dA0C898a5c9FB9D17ceD60b1B;

    // Pool parameters
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Adding Liquidity to V3 Pool ===");
        console.log("Deployer:", deployer);
        console.log("");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(GRIM_SWAP_ZK_V3)
        });

        vm.startBroadcast(deployerPrivateKey);

        // Deploy a new PoolTestHelper
        PoolTestHelper helper = new PoolTestHelper(IPoolManager(POOL_MANAGER));
        console.log("PoolTestHelper deployed:", address(helper));

        // Amount of liquidity (100k of each token)
        uint256 amount = 100000 * 10**18;
        int24 tickLower = -6000;
        int24 tickUpper = 6000;

        IERC20(TOKEN_A).approve(address(helper), amount);
        IERC20(TOKEN_B).approve(address(helper), amount);
        console.log("Tokens approved");

        console.log("Adding liquidity...");
        helper.addLiquidity(
            poolKey,
            tickLower,
            tickUpper,
            amount,
            amount,
            deployer
        );
        console.log("Liquidity added!");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Liquidity Added Successfully ===");
        console.log("PoolHelper:", address(helper));
    }
}
