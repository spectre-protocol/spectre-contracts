// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IGrimPool} from "./interfaces/IGrimPool.sol";
import {IGroth16Verifier} from "./interfaces/IGroth16Verifier.sol";

/**
 * @title GrimSwapZK
 * @author GrimSwap (github.com/grimswap)
 * @notice Uniswap v4 hook for privacy-preserving swaps using ZK proofs
 * @dev Uses Groth16 ZK-SNARKs to prove membership in deposit pool without revealing identity
 *
 * Privacy guarantees:
 * 1. Sender hidden: ZK proof proves membership in anonymity set (all depositors)
 * 2. Recipient hidden: Output goes to stealth address
 * 3. Gas payer hidden: Relayer submits transaction
 */
contract GrimSwapZK is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidProof();
    error InvalidMerkleRoot();
    error NullifierAlreadyUsed();
    error InvalidRecipient();
    error InvalidRelayerFee();
    error SwapNotInitialized();
    error UnauthorizedRelayer();
    error TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PrivateSwapExecuted(
        bytes32 indexed nullifierHash,
        address indexed recipient,
        address indexed relayer,
        uint256 amount,
        uint256 fee,
        uint256 timestamp
    );

    event StealthPayment(
        address indexed stealthAddress,
        address indexed token,
        uint256 amount,
        uint256 fee,
        address relayer
    );

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum relayer fee (10% = 1000 basis points)
    uint256 public constant MAX_RELAYER_FEE_BPS = 1000;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Groth16 verifier contract
    IGroth16Verifier public immutable verifier;

    /// @notice Deposit pool with Merkle tree
    IGrimPool public immutable grimPool;

    /// @notice Mapping of authorized relayers (optional whitelist)
    mapping(address => bool) public authorizedRelayers;

    /// @notice Whether relayer whitelist is enabled
    bool public relayerWhitelistEnabled;

    /// @notice Temporary storage for pending swap data
    struct PendingSwap {
        address recipient;
        address relayer;
        uint256 relayerFeeBps;
        bytes32 nullifierHash;
        bool initialized;
    }

    mapping(address => PendingSwap) private pendingSwaps;

    /// @notice Total private swaps executed
    uint256 public totalPrivateSwaps;

    /// @notice Total volume swapped privately
    uint256 public totalPrivateVolume;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IPoolManager _poolManager,
        IGroth16Verifier _verifier,
        IGrimPool _grimPool
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        verifier = _verifier;
        grimPool = _grimPool;
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
            beforeSwap: true,           // Verify ZK proof
            afterSwap: true,            // Route to stealth address
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

    /**
     * @notice Verify ZK proof before swap execution
     * @dev Called by relayer, decodes proof from hookData
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata /* key */,
        SwapParams calldata /* params */,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // DUAL-MODE: If no hookData, this is a regular swap - pass through
        if (hookData.length == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Decode ZK proof and public signals from hookData
        (
            uint256[2] memory pA,
            uint256[2][2] memory pB,
            uint256[2] memory pC,
            uint256[8] memory pubSignals
        ) = abi.decode(hookData, (uint256[2], uint256[2][2], uint256[2], uint256[8]));

        // Extract public signals (snarkjs outputs first, then inputs)
        // pubSignals[0] = computedCommitment (circuit output)
        // pubSignals[1] = computedNullifierHash (circuit output)
        // pubSignals[2] = merkleRoot (circuit input)
        // pubSignals[3] = nullifierHash (circuit input)
        // pubSignals[4] = recipient (circuit input)
        // pubSignals[5] = relayer (circuit input)
        // pubSignals[6] = relayerFee (circuit input)
        // pubSignals[7] = swapAmountOut (circuit input)

        bytes32 merkleRoot = bytes32(pubSignals[2]);
        bytes32 nullifierHash = bytes32(pubSignals[3]);
        address recipient = address(uint160(pubSignals[4]));
        address relayer = address(uint160(pubSignals[5]));
        uint256 relayerFeeBps = pubSignals[6];

        // Validate merkle root is known
        if (!grimPool.isKnownRoot(merkleRoot)) {
            revert InvalidMerkleRoot();
        }

        // Check nullifier hasn't been used
        if (grimPool.isSpent(nullifierHash)) {
            revert NullifierAlreadyUsed();
        }

        // Validate recipient
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }

        // Validate relayer fee
        if (relayerFeeBps > MAX_RELAYER_FEE_BPS) {
            revert InvalidRelayerFee();
        }

        // Check relayer authorization (if whitelist enabled)
        if (relayerWhitelistEnabled && relayer != address(0)) {
            if (!authorizedRelayers[relayer]) {
                revert UnauthorizedRelayer();
            }
        }

        // Verify ZK proof
        bool isValid = verifier.verifyProof(pA, pB, pC, pubSignals);
        if (!isValid) {
            revert InvalidProof();
        }

        // Mark nullifier as spent
        grimPool.markNullifierAsSpent(nullifierHash);

        // Store pending swap data for afterSwap
        pendingSwaps[sender] = PendingSwap({
            recipient: recipient,
            relayer: relayer,
            relayerFeeBps: relayerFeeBps,
            nullifierHash: nullifierHash,
            initialized: true
        });

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               AFTER SWAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Route swap output to stealth address
     * @dev Takes output tokens from pool and transfers to recipient/relayer
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        PendingSwap memory pending = pendingSwaps[sender];

        // DUAL-MODE: If no pending swap, this is a regular swap - pass through
        if (!pending.initialized) {
            return (this.afterSwap.selector, 0);
        }

        // Determine output token and amount
        int128 outputAmount;
        Currency outputCurrency;

        if (params.zeroForOne) {
            // Swapping token0 -> token1, output is token1
            outputAmount = delta.amount1();
            outputCurrency = key.currency1;
        } else {
            // Swapping token1 -> token0, output is token0
            outputAmount = delta.amount0();
            outputCurrency = key.currency0;
        }

        // Output amount is negative (tokens owed to swapper)
        // Convert to positive for transfer calculations
        uint256 absOutput = outputAmount < 0
            ? uint256(uint128(-outputAmount))
            : uint256(uint128(outputAmount));

        // Calculate relayer fee
        uint256 feeAmount = 0;
        if (pending.relayer != address(0) && pending.relayerFeeBps > 0) {
            feeAmount = (absOutput * pending.relayerFeeBps) / BPS_DENOMINATOR;
        }

        uint256 recipientAmount = absOutput - feeAmount;

        // Take tokens from the PoolManager and send to recipients
        // The hook claims the output tokens and redirects them
        if (absOutput > 0) {
            // Take output tokens from pool to this contract
            poolManager.take(outputCurrency, address(this), absOutput);

            address token = Currency.unwrap(outputCurrency);

            // Transfer to stealth address (recipient)
            if (recipientAmount > 0) {
                if (outputCurrency.isAddressZero()) {
                    // Native ETH
                    (bool success, ) = pending.recipient.call{value: recipientAmount}("");
                    if (!success) revert TransferFailed();
                } else {
                    // ERC20
                    IERC20(token).safeTransfer(pending.recipient, recipientAmount);
                }
            }

            // Transfer fee to relayer
            if (feeAmount > 0 && pending.relayer != address(0)) {
                if (outputCurrency.isAddressZero()) {
                    // Native ETH
                    (bool success, ) = pending.relayer.call{value: feeAmount}("");
                    if (!success) revert TransferFailed();
                } else {
                    // ERC20
                    IERC20(token).safeTransfer(pending.relayer, feeAmount);
                }
            }
        }

        // Update stats
        totalPrivateSwaps++;
        totalPrivateVolume += absOutput;

        // Emit stealth payment event for recipient to scan
        emit StealthPayment(
            pending.recipient,
            Currency.unwrap(outputCurrency),
            recipientAmount,
            feeAmount,
            pending.relayer
        );

        emit PrivateSwapExecuted(
            pending.nullifierHash,
            pending.recipient,
            pending.relayer,
            recipientAmount,
            feeAmount,
            block.timestamp
        );

        // Clear pending swap
        delete pendingSwaps[sender];

        // Return the output amount as hook delta
        // This tells the PoolManager that the hook took these tokens
        return (this.afterSwap.selector, outputAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enable/disable relayer whitelist
     */
    function setRelayerWhitelistEnabled(bool enabled) external onlyOwner {
        relayerWhitelistEnabled = enabled;
    }

    /**
     * @notice Add/remove authorized relayer
     */
    function setAuthorizedRelayer(address relayer, bool authorized) external onlyOwner {
        authorizedRelayers[relayer] = authorized;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get protocol statistics
     */
    function getStats() external view returns (
        uint256 swaps,
        uint256 volume
    ) {
        return (totalPrivateSwaps, totalPrivateVolume);
    }

    /**
     * @notice Check if a nullifier has been used
     */
    function isNullifierUsed(bytes32 nullifierHash) external view returns (bool) {
        return grimPool.isSpent(nullifierHash);
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow contract to receive ETH for native token swaps
    receive() external payable {}
}
