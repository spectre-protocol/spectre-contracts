// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRingVerifier
/// @notice Interface for LSAG ring signature verification
interface IRingVerifier {
    /// @notice Verifies a ring signature
    /// @param message The message that was signed
    /// @param signature The ring signature bytes
    /// @param keyImage The key image (unique per private key, prevents double-spend)
    /// @param ringMembers Array of public keys in the ring
    /// @return valid True if signature is valid
    function verifyRingSignature(
        bytes32 message,
        bytes calldata signature,
        bytes32 keyImage,
        address[] calldata ringMembers
    ) external view returns (bool valid);
}
