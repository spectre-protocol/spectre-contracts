// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IGrimPool
 * @notice Interface for the GrimSwap deposit pool with Merkle tree
 */
interface IGrimPool {
    /**
     * @notice Deposit funds and add commitment to Merkle tree
     * @param commitment The Poseidon hash of (nullifier, secret, amount)
     */
    function deposit(bytes32 commitment) external payable;

    /**
     * @notice Get the current Merkle root
     * @return The current root of the Merkle tree
     */
    function getLastRoot() external view returns (bytes32);

    /**
     * @notice Check if a root is known (recent)
     * @param root The root to check
     * @return True if the root is in recent history
     */
    function isKnownRoot(bytes32 root) external view returns (bool);

    /**
     * @notice Check if a nullifier has been used
     * @param nullifierHash The nullifier hash to check
     * @return True if the nullifier has been spent
     */
    function isSpent(bytes32 nullifierHash) external view returns (bool);

    /**
     * @notice Check if a commitment exists
     * @param commitment The commitment to check
     * @return True if the commitment exists
     */
    function isCommitmentExists(bytes32 commitment) external view returns (bool);

    /**
     * @notice Get the number of deposits
     * @return The total number of deposits
     */
    function getDepositCount() external view returns (uint32);

    /**
     * @notice Mark a nullifier as spent
     * @param nullifierHash The nullifier hash to mark
     */
    function markNullifierAsSpent(bytes32 nullifierHash) external;

    /**
     * @notice Release deposited ETH for a private swap
     * @dev Only callable by authorized routers or GrimSwapZK hook
     * @param amount Amount of ETH to release
     */
    function releaseForSwap(uint256 amount) external;
}
