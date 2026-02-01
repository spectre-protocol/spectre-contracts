// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStealthAddressRegistry
/// @notice Interface for stealth address registration and generation (ERC-5564)
interface IStealthAddressRegistry {
    /// @notice Emitted when a stealth meta-address is registered
    event StealthMetaAddressRegistered(address indexed registrant, bytes stealthMetaAddress);

    /// @notice Register a stealth meta-address for receiving private payments
    /// @param stealthMetaAddress The stealth meta-address (spending pubkey || viewing pubkey)
    function registerStealthMetaAddress(bytes calldata stealthMetaAddress) external;

    /// @notice Get the registered stealth meta-address for an account
    /// @param account The account to query
    /// @return The stealth meta-address, or empty bytes if not registered
    function getStealthMetaAddress(address account) external view returns (bytes memory);

    /// @notice Generate a one-time stealth address from a meta-address
    /// @param stealthMetaAddress The recipient's stealth meta-address
    /// @return stealthAddress The generated stealth address
    /// @return ephemeralPubKey The ephemeral public key for the recipient to derive the private key
    /// @return viewTag A view tag for efficient scanning
    function generateStealthAddress(bytes calldata stealthMetaAddress)
        external
        returns (address stealthAddress, bytes memory ephemeralPubKey, uint8 viewTag);
}
