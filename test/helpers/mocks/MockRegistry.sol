// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockRegistry
/// @notice Simple registry mock for testing MetaWallet hook execution
/// @dev Allows all whitelisted targets and their function calls
contract MockRegistry {
    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    mapping(address => bool) public whitelistedTargets;

    /* ///////////////////////////////////////////////////////////////
                              WHITELIST
    ///////////////////////////////////////////////////////////////*/

    /// @notice Whitelist a target address
    /// @param _target The address to whitelist
    function whitelistTarget(address _target) external {
        whitelistedTargets[_target] = true;
    }

    /// @notice Remove a target from whitelist
    /// @param _target The address to remove
    function removeTarget(address _target) external {
        whitelistedTargets[_target] = false;
    }

    /* ///////////////////////////////////////////////////////////////
                              AUTHORIZATION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Authorize an adapter call
    /// @param _target The target address to call
    /// @param _functionSig The function selector
    /// @param _params The function parameters
    function authorizeAdapterCall(address _target, bytes4 _functionSig, bytes memory _params) external view {
        require(whitelistedTargets[_target], "Target not whitelisted");
        // In production, this would do more sophisticated checks
        // For testing, we just check if target is whitelisted
    }

    /// @notice Check if a target is whitelisted
    /// @param _target The address to check
    /// @return _isWhitelisted Whether the target is whitelisted
    function isWhitelisted(address _target) external view returns (bool _isWhitelisted) {
        return whitelistedTargets[_target];
    }
}
