// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IRingVerifier} from "./interfaces/IRingVerifier.sol";
import {IStealthAddressRegistry} from "./interfaces/IStealthAddressRegistry.sol";
import {IERC5564Announcer} from "./interfaces/IERC5564Announcer.sol";

/// @title SpectreHook
/// @author Spectre Protocol
/// @notice Uniswap v4 hook enabling private swaps via ring signatures and stealth addresses
/// @dev Combines LSAG ring signatures (sender privacy) with ERC-5564 stealth addresses (recipient privacy)
contract SpectreHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidRingSignature();
    error KeyImageAlreadyUsed();
    error InvalidStealthMetaAddress();
    error InsufficientRingSize();
    error SwapNotInitialized();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PrivateSwapInitiated(
        bytes32 indexed poolId,
        bytes32 indexed keyImage,
        uint256 ringSize,
        uint256 timestamp
    );

    event PrivateSwapCompleted(
        bytes32 indexed poolId,
        address indexed stealthAddress,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MIN_RING_SIZE = 2;
    uint256 public constant MAX_RING_SIZE = 10;
    uint256 public constant STEALTH_SCHEME_ID = 1; // ERC-5564 secp256k1

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IRingVerifier public immutable ringVerifier;
    IStealthAddressRegistry public immutable stealthRegistry;
    IERC5564Announcer public immutable announcer;

    /// @notice Tracks used key images to prevent double-spending
    mapping(bytes32 => bool) public usedKeyImages;

    /// @notice Temporary storage for pending swap data
    struct PendingSwap {
        bytes stealthMetaAddress;
        bytes32 keyImage;
        bool initialized;
    }

    mapping(address => PendingSwap) private pendingSwaps;

    /// @notice Total private swaps executed (for stats)
    uint256 public totalPrivateSwaps;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IPoolManager _poolManager,
        IRingVerifier _ringVerifier,
        IStealthAddressRegistry _stealthRegistry,
        IERC5564Announcer _announcer
    ) BaseHook(_poolManager) {
        ringVerifier = _ringVerifier;
        stealthRegistry = _stealthRegistry;
        announcer = _announcer;
    }

    /*//////////////////////////////////////////////////////////////
                            HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Verify ring signature
            afterSwap: true, // Route to stealth address
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // Redirect output tokens
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                              BEFORE SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies ring signature before swap execution
    /// @dev Decodes hookData, verifies signature, stores pending swap data
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // If no hookData, this is a regular (non-private) swap
        if (hookData.length == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Decode hook data
        (
            bytes memory ringSignature,
            bytes32 keyImage,
            address[] memory ringMembers,
            bytes memory stealthMetaAddress
        ) = abi.decode(hookData, (bytes, bytes32, address[], bytes));

        // Validate ring size
        if (ringMembers.length < MIN_RING_SIZE || ringMembers.length > MAX_RING_SIZE) {
            revert InsufficientRingSize();
        }

        // Check key image hasn't been used (prevents double-spend)
        if (usedKeyImages[keyImage]) {
            revert KeyImageAlreadyUsed();
        }

        // Create message hash for verification
        bytes32 message = keccak256(
            abi.encode(key.toId(), params.zeroForOne, params.amountSpecified, block.chainid, address(this))
        );

        // Verify ring signature
        bool isValid = ringVerifier.verifyRingSignature(message, ringSignature, keyImage, ringMembers);

        if (!isValid) {
            revert InvalidRingSignature();
        }

        // Validate stealth meta-address (33 bytes spending + 33 bytes viewing)
        if (stealthMetaAddress.length != 66) {
            revert InvalidStealthMetaAddress();
        }

        // Mark key image as used
        usedKeyImages[keyImage] = true;

        // Store pending swap data for afterSwap
        pendingSwaps[sender] = PendingSwap({
            stealthMetaAddress: stealthMetaAddress,
            keyImage: keyImage,
            initialized: true
        });

        emit PrivateSwapInitiated(
            PoolId.unwrap(key.toId()), keyImage, ringMembers.length, block.timestamp
        );

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               AFTER SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Routes swap output to stealth address
    /// @dev Generates stealth address, emits announcement, returns delta
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        PendingSwap storage pending = pendingSwaps[sender];

        // If no pending private swap, return zero delta (regular swap)
        if (!pending.initialized) {
            return (this.afterSwap.selector, 0);
        }

        // Generate one-time stealth address
        (address stealthAddress, bytes memory ephemeralPubKey, uint8 viewTag) =
            stealthRegistry.generateStealthAddress(pending.stealthMetaAddress);

        // Determine output token and amount
        int128 outputAmount;
        Currency outputCurrency;

        if (params.zeroForOne) {
            outputAmount = delta.amount1();
            outputCurrency = key.currency1;
        } else {
            outputAmount = delta.amount0();
            outputCurrency = key.currency0;
        }

        // Emit ERC-5564 announcement for recipient to scan
        announcer.announce(
            STEALTH_SCHEME_ID,
            stealthAddress,
            ephemeralPubKey,
            abi.encodePacked(
                viewTag, Currency.unwrap(outputCurrency), uint256(uint128(outputAmount > 0 ? outputAmount : -outputAmount))
            )
        );

        emit PrivateSwapCompleted(
            PoolId.unwrap(key.toId()),
            stealthAddress,
            Currency.unwrap(outputCurrency),
            uint256(uint128(outputAmount > 0 ? outputAmount : -outputAmount)),
            block.timestamp
        );

        // Increment stats
        totalPrivateSwaps++;

        // Clear pending swap data
        delete pendingSwaps[sender];

        // Return delta to redirect funds to stealth address
        // Note: In production, this would integrate with PoolManager's settlement
        return (this.afterSwap.selector, outputAmount);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if a key image has been used
    function isKeyImageUsed(bytes32 keyImage) external view returns (bool) {
        return usedKeyImages[keyImage];
    }

    /// @notice Get protocol statistics
    function getStats() external view returns (uint256 swaps) {
        return totalPrivateSwaps;
    }
}
