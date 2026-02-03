// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGrimPool} from "./interfaces/IGrimPool.sol";

/**
 * @title GrimPool
 * @author GrimSwap (github.com/grimswap)
 * @notice Deposit pool with Merkle tree for ZK privacy
 * @dev Users deposit funds and receive a commitment that's added to a Merkle tree.
 *      Later, they can prove membership in the tree using a ZK proof to swap privately.
 */
contract GrimPool is IGrimPool, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Height of the Merkle tree (2^20 = ~1M deposits)
    uint32 public constant MERKLE_TREE_HEIGHT = 20;

    /// @notice Maximum number of leaves (2^20)
    uint32 public constant MAX_DEPOSITS = uint32(1 << MERKLE_TREE_HEIGHT);

    /// @notice Field modulus for BN254 curve (used by Groth16)
    uint256 public constant FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice Zero value for empty leaves
    uint256 public constant ZERO_VALUE =
        21663839004416932945382355908790599225266501822907911457504978515578255421292;

    /// @notice Number of recent roots to store (prevents front-running)
    uint32 public constant ROOT_HISTORY_SIZE = 30;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Current index for next deposit
    uint32 public nextLeafIndex;

    /// @notice Mapping of nullifier hashes to spent status
    mapping(bytes32 => bool) public nullifierHashes;

    /// @notice Mapping of commitment hashes to existence
    mapping(bytes32 => bool) public commitments;

    /// @notice Array of filled subtrees for efficient updates
    bytes32[MERKLE_TREE_HEIGHT] public filledSubtrees;

    /// @notice Recent roots history (circular buffer)
    bytes32[ROOT_HISTORY_SIZE] public roots;

    /// @notice Current root index in circular buffer
    uint32 public currentRootIndex;

    /// @notice Precomputed zero hashes for each level
    bytes32[MERKLE_TREE_HEIGHT] public zeros;

    /// @notice Address of the GrimSwapZK hook (authorized to mark nullifiers)
    address public grimSwapZK;

    /// @notice Owner of the contract (for admin functions)
    address public owner;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        bytes32 indexed commitment,
        uint32 leafIndex,
        uint256 timestamp
    );

    event Withdrawal(
        address indexed recipient,
        bytes32 nullifierHash,
        address indexed relayer,
        uint256 fee
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidCommitment();
    error CommitmentAlreadyExists();
    error MerkleTreeFull();
    error InvalidMerkleRoot();
    error NullifierAlreadyUsed();
    error InvalidWithdrawProof();
    error InvalidRecipient();
    error Unauthorized();
    error AlreadyInitialized();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = msg.sender;

        // Initialize zero hashes
        bytes32 currentZero = bytes32(ZERO_VALUE);
        zeros[0] = currentZero;
        filledSubtrees[0] = currentZero;

        for (uint32 i = 1; i < MERKLE_TREE_HEIGHT; i++) {
            currentZero = _hashLeftRight(currentZero, currentZero);
            zeros[i] = currentZero;
            filledSubtrees[i] = currentZero;
        }

        // Initialize first root
        roots[0] = _hashLeftRight(zeros[MERKLE_TREE_HEIGHT - 1], zeros[MERKLE_TREE_HEIGHT - 1]);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit funds and add commitment to Merkle tree
     * @param commitment The Poseidon hash of (nullifier, secret, amount)
     */
    function deposit(bytes32 commitment) external payable nonReentrant {
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (uint256(commitment) >= FIELD_SIZE) revert InvalidCommitment();
        if (commitments[commitment]) revert CommitmentAlreadyExists();
        if (nextLeafIndex >= MAX_DEPOSITS) revert MerkleTreeFull();

        // Mark commitment as used
        commitments[commitment] = true;

        // Insert into Merkle tree
        uint32 leafIndex = nextLeafIndex;
        bytes32 newRoot = _insert(commitment);

        // Store new root
        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        roots[currentRootIndex] = newRoot;

        // Increment leaf index
        nextLeafIndex = leafIndex + 1;

        emit Deposit(commitment, leafIndex, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          MERKLE TREE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Insert a leaf into the Merkle tree
     * @param leaf The leaf to insert
     * @return newRoot The new Merkle root
     */
    function _insert(bytes32 leaf) internal returns (bytes32 newRoot) {
        uint32 currentIndex = nextLeafIndex;
        bytes32 currentLevelHash = leaf;
        bytes32 left;
        bytes32 right;

        for (uint32 i = 0; i < MERKLE_TREE_HEIGHT; i++) {
            if (currentIndex % 2 == 0) {
                // Current node is left child
                left = currentLevelHash;
                right = zeros[i];
                filledSubtrees[i] = currentLevelHash;
            } else {
                // Current node is right child
                left = filledSubtrees[i];
                right = currentLevelHash;
            }
            currentLevelHash = _hashLeftRight(left, right);
            currentIndex /= 2;
        }

        return currentLevelHash;
    }

    /**
     * @notice Hash two children using Poseidon (simulated with keccak for now)
     * @dev In production, use actual Poseidon hash via precompile or library
     */
    function _hashLeftRight(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        // Using keccak256 for compatibility
        // In production, replace with Poseidon hash
        return bytes32(uint256(keccak256(abi.encodePacked(left, right))) % FIELD_SIZE);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the current Merkle root
     */
    function getLastRoot() external view returns (bytes32) {
        return roots[currentRootIndex];
    }

    /**
     * @notice Check if a root is known (recent)
     * @param root The root to check
     */
    function isKnownRoot(bytes32 root) public view returns (bool) {
        if (root == bytes32(0)) return false;

        uint32 currentIdx = currentRootIndex;
        for (uint32 i = 0; i < ROOT_HISTORY_SIZE; i++) {
            if (roots[currentIdx] == root) return true;
            if (currentIdx == 0) {
                currentIdx = ROOT_HISTORY_SIZE - 1;
            } else {
                currentIdx--;
            }
        }
        return false;
    }

    /**
     * @notice Check if a nullifier has been used
     * @param nullifierHash The nullifier hash to check
     */
    function isSpent(bytes32 nullifierHash) external view returns (bool) {
        return nullifierHashes[nullifierHash];
    }

    /**
     * @notice Check if a commitment exists
     * @param commitment The commitment to check
     */
    function isCommitmentExists(bytes32 commitment) external view returns (bool) {
        return commitments[commitment];
    }

    /**
     * @notice Get the number of deposits
     */
    function getDepositCount() external view returns (uint32) {
        return nextLeafIndex;
    }

    /**
     * @notice Get zero hash at a specific level
     */
    function getZeroValue(uint32 level) external view returns (bytes32) {
        require(level < MERKLE_TREE_HEIGHT, "Level out of bounds");
        return zeros[level];
    }

    /**
     * @notice Get filled subtree at a specific level
     */
    function getFilledSubtree(uint32 level) external view returns (bytes32) {
        require(level < MERKLE_TREE_HEIGHT, "Level out of bounds");
        return filledSubtrees[level];
    }

    /*//////////////////////////////////////////////////////////////
                         NULLIFIER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mark a nullifier as spent (called by GrimSwapZK)
     * @param nullifierHash The nullifier hash to mark
     */
    function markNullifierAsSpent(bytes32 nullifierHash) external {
        if (msg.sender != grimSwapZK) revert Unauthorized();
        if (nullifierHashes[nullifierHash]) revert NullifierAlreadyUsed();
        nullifierHashes[nullifierHash] = true;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the GrimSwapZK hook address (one-time setup)
     * @param _grimSwapZK Address of the GrimSwapZK hook
     */
    function setGrimSwapZK(address _grimSwapZK) external {
        if (msg.sender != owner) revert Unauthorized();
        if (grimSwapZK != address(0)) revert AlreadyInitialized();
        grimSwapZK = _grimSwapZK;
    }

    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        owner = newOwner;
    }

    /**
     * @notice Add a known root (TESTNET ONLY - for Poseidon tree compatibility)
     * @dev This allows adding Poseidon-based Merkle roots for ZK proofs
     * @param root The Poseidon Merkle root to add
     */
    function addKnownRoot(bytes32 root) external {
        if (msg.sender != owner) revert Unauthorized();
        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        roots[currentRootIndex] = root;
    }
}
