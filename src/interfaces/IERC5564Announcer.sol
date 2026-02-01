// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IERC5564Announcer
/// @notice Interface for ERC-5564 stealth address announcements
/// @dev See https://eips.ethereum.org/EIPS/eip-5564
interface IERC5564Announcer {
    /// @notice Emitted when a stealth address payment is announced
    /// @param schemeId The stealth address scheme (1 = secp256k1)
    /// @param stealthAddress The generated stealth address
    /// @param caller The address making the announcement
    /// @param ephemeralPubKey The ephemeral public key for deriving the stealth private key
    /// @param metadata Additional data (view tag, token address, amount, etc.)
    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes ephemeralPubKey,
        bytes metadata
    );

    /// @notice Announce a stealth address payment
    /// @param schemeId The stealth address scheme ID
    /// @param stealthAddress The generated stealth address
    /// @param ephemeralPubKey The ephemeral public key
    /// @param metadata Additional payment metadata
    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external;
}
