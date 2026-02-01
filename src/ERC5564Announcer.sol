// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC5564Announcer} from "./interfaces/IERC5564Announcer.sol";

/// @title ERC5564Announcer
/// @author Spectre Protocol
/// @notice Announces stealth address payments per ERC-5564
/// @dev Recipients scan these events to find payments sent to them
contract ERC5564Announcer is IERC5564Announcer {
    /// @inheritdoc IERC5564Announcer
    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external {
        emit Announcement(schemeId, stealthAddress, msg.sender, ephemeralPubKey, metadata);
    }
}
