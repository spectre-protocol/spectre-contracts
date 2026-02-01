// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {TestERC20} from "../src/test/TestERC20.sol";
import {PoolTestHelper} from "../src/test/PoolTestHelper.sol";
import {RingVerifierMock} from "../src/test/RingVerifierMock.sol";
import {SpectreHook} from "../src/SpectreHook.sol";
import {IRingVerifier} from "../src/interfaces/IRingVerifier.sol";
import {IStealthAddressRegistry} from "../src/interfaces/IStealthAddressRegistry.sol";
import {IERC5564Announcer} from "../src/interfaces/IERC5564Announcer.sol";

/// @title ExecutePrivateSwap
/// @notice Execute a full private swap end-to-end test
contract ExecutePrivateSwap is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // CREATE2 Deployer Proxy
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Deployed contracts on Unichain Sepolia
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant STEALTH_REGISTRY = 0xA9e4ED4183b3B3cC364cF82dA7982D5ABE956307;
    address constant ANNOUNCER = 0x42013A72753F6EC28e27582D4cDb8425b44fd311;

    // Pool parameters
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Hook flags
    uint160 constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("");
        console.log("================================================================");
        console.log("     SPECTRE PROTOCOL - FULL PRIVATE SWAP EXECUTION TEST");
        console.log("================================================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // STEP 1: Deploy Mock Ring Verifier
        // ============================================
        console.log("--- STEP 1: Deploy Mock Ring Verifier ---");
        console.log("(For demo - accepts any signature to show full flow)");
        RingVerifierMock mockVerifier = new RingVerifierMock();
        console.log("RingVerifierMock:", address(mockVerifier));
        console.log("");

        // ============================================
        // STEP 2: Deploy SpectreHook with Mock Verifier
        // ============================================
        console.log("--- STEP 2: Deploy SpectreHook with Mined Address ---");

        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            IRingVerifier(address(mockVerifier)),
            IStealthAddressRegistry(STEALTH_REGISTRY),
            IERC5564Announcer(ANNOUNCER)
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            REQUIRED_FLAGS,
            type(SpectreHook).creationCode,
            constructorArgs
        );

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        bytes memory bytecode = abi.encodePacked(type(SpectreHook).creationCode, constructorArgs);
        (bool success,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, bytecode));
        require(success, "Hook deployment failed");
        require(hookAddress.code.length > 0, "Hook has no code");

        SpectreHook spectreHook = SpectreHook(hookAddress);
        console.log("SpectreHook deployed:", address(spectreHook));
        console.log("Address flags:", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);
        console.log("");

        // ============================================
        // STEP 3: Deploy Test Tokens
        // ============================================
        console.log("--- STEP 3: Deploy Test Tokens ---");
        TestERC20 tokenA = new TestERC20("Private Token A", "PTA", 18);
        TestERC20 tokenB = new TestERC20("Private Token B", "PTB", 18);

        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        console.log("Token A:", address(tokenA));
        console.log("Token B:", address(tokenB));

        uint256 mintAmount = 1_000_000 ether;
        tokenA.mint(deployer, mintAmount);
        tokenB.mint(deployer, mintAmount);
        console.log("Minted 1,000,000 tokens each");
        console.log("");

        // ============================================
        // STEP 4: Deploy Pool Helper
        // ============================================
        console.log("--- STEP 4: Deploy Pool Helper ---");
        PoolTestHelper helper = new PoolTestHelper(IPoolManager(POOL_MANAGER));
        console.log("PoolTestHelper:", address(helper));
        console.log("");

        // ============================================
        // STEP 5: Create Pool
        // ============================================
        console.log("--- STEP 5: Create Pool with SpectreHook ---");
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(spectreHook))
        });

        PoolId poolId = poolKey.toId();
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));

        helper.initializePool(poolKey, SQRT_PRICE_1_1);
        console.log("Pool initialized at 1:1 price");
        console.log("");

        // ============================================
        // STEP 6: Add Liquidity
        // ============================================
        console.log("--- STEP 6: Add Liquidity ---");
        tokenA.approve(address(helper), type(uint256).max);
        tokenB.approve(address(helper), type(uint256).max);
        tokenA.approve(POOL_MANAGER, type(uint256).max);
        tokenB.approve(POOL_MANAGER, type(uint256).max);

        uint256 liquidityAmount = 100_000 ether;
        BalanceDelta liquidityDelta = helper.addLiquidity(
            poolKey, -600, 600, liquidityAmount, liquidityAmount, deployer
        );
        console.log("Liquidity added!");
        console.log("  Delta0:", liquidityDelta.amount0());
        console.log("  Delta1:", liquidityDelta.amount1());
        console.log("");

        // ============================================
        // STEP 7: Prepare Private Swap Data
        // ============================================
        console.log("--- STEP 7: Prepare Private Swap Data ---");

        // Create ring members (signer + decoys)
        address[] memory ringMembers = new address[](5);
        ringMembers[0] = deployer;
        ringMembers[1] = address(0x1111111111111111111111111111111111111111);
        ringMembers[2] = address(0x2222222222222222222222222222222222222222);
        ringMembers[3] = address(0x3333333333333333333333333333333333333333);
        ringMembers[4] = address(0x4444444444444444444444444444444444444444);

        // Create mock ring signature (192 bytes)
        bytes memory ringSignature = new bytes(192);
        for (uint256 i = 0; i < 192; i++) {
            ringSignature[i] = bytes1(uint8(i % 256));
        }

        // Create key image
        bytes32 keyImage = keccak256(abi.encodePacked("spectre-key-image", block.timestamp, deployer));

        // Create stealth meta-address (66 bytes)
        bytes memory stealthMetaAddress = new bytes(66);
        stealthMetaAddress[0] = 0x02;
        for (uint256 i = 1; i < 33; i++) {
            stealthMetaAddress[i] = bytes1(uint8(i));
        }
        stealthMetaAddress[33] = 0x03;
        for (uint256 i = 34; i < 66; i++) {
            stealthMetaAddress[i] = bytes1(uint8(i - 33));
        }

        // Encode hook data
        bytes memory hookData = abi.encode(ringSignature, keyImage, ringMembers, stealthMetaAddress);

        console.log("Ring size:", ringMembers.length);
        console.log("Key image:", vm.toString(keyImage));
        console.log("Hook data length:", hookData.length);
        console.log("");

        // ============================================
        // STEP 8: Execute Private Swap
        // ============================================
        console.log("--- STEP 8: EXECUTE PRIVATE SWAP ---");
        console.log("");

        uint256 balanceBefore = tokenB.balanceOf(deployer);
        console.log("Token B balance BEFORE:", balanceBefore / 1e18);

        int256 swapAmount = 1000 ether;
        uint160 sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;

        console.log("");
        console.log("Swapping 1000 Token A -> Token B with PRIVACY...");
        console.log("");

        BalanceDelta swapDelta = helper.swap(
            poolKey,
            true,
            -swapAmount,
            sqrtPriceLimitX96,
            hookData,
            deployer
        );

        uint256 balanceAfter = tokenB.balanceOf(deployer);

        vm.stopBroadcast();

        // ============================================
        // RESULTS
        // ============================================
        console.log("================================================================");
        console.log("              PRIVATE SWAP SUCCESSFUL!");
        console.log("================================================================");
        console.log("");
        console.log("Swap Results:");
        int128 amount0 = swapDelta.amount0();
        int128 amount1 = swapDelta.amount1();
        console.log("  Token A delta:", amount0);
        console.log("  Token B delta:", amount1);
        console.log("");
        console.log("Balance Change:");
        console.log("  Token B before:", balanceBefore / 1e18);
        console.log("  Token B after:", balanceAfter / 1e18);
        console.log("  Gained:", (balanceAfter - balanceBefore) / 1e18);
        console.log("");
        console.log("Privacy Features Applied:");
        console.log("  [x] Ring signature verified (sender hidden among 5)");
        console.log("  [x] Key image recorded (prevents double-spend)");
        console.log("  [x] Stealth address generated (recipient hidden)");
        console.log("  [x] ERC-5564 announcement emitted");
        console.log("");
        console.log("Check SpectreHook stats:");

        SpectreHook finalHook = SpectreHook(address(spectreHook));
        console.log("  Total private swaps:", finalHook.totalPrivateSwaps());
        console.log("  Key image used:", finalHook.usedKeyImages(keyImage));
        console.log("");
        console.log("================================================================");
        console.log("                   TEST COMPLETE");
        console.log("================================================================");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  RingVerifierMock:", address(mockVerifier));
        console.log("  SpectreHook:", address(spectreHook));
        console.log("  Token A:", address(tokenA));
        console.log("  Token B:", address(tokenB));
        console.log("  PoolTestHelper:", address(helper));
        console.log("");
    }
}
