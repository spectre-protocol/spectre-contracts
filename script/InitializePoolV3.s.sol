// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title InitializePoolV3
/// @notice Initialize pool with GrimSwapZK V3 (dual-mode) hook
contract InitializePoolV3 is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Unichain Sepolia contracts
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant GRIM_SWAP_ZK_V3 = 0xeB72E2495640a4B83EBfc4618FD91cc9beB640c4;

    // Existing test tokens
    address constant TOKEN_A = 0x48bA64b5312AFDfE4Fc96d8F03010A0a86e17963;
    address constant TOKEN_B = 0x96aC37889DfDcd4dA0C898a5c9FB9D17ceD60b1B;

    // Pool parameters
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Initialize Pool with GrimSwapZK V3 (Dual-Mode) ===");
        console.log("Deployer:", deployer);
        console.log("GrimSwapZK V3:", GRIM_SWAP_ZK_V3);
        console.log("");

        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(GRIM_SWAP_ZK_V3)
        });

        PoolId poolId = poolKey.toId();
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));

        vm.startBroadcast(deployerPrivateKey);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            console.log("Initializing pool...");
            poolManager.initialize(poolKey, SQRT_PRICE_1_1);
            console.log("Pool initialized at 1:1 price");
        } else {
            console.log("Pool already exists, sqrtPriceX96:", sqrtPriceX96);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Pool Ready ===");
        console.log("Next: Run AddLiquidityV3");
    }
}
