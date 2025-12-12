// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";

/// @title MockRegistry
/// @notice Mock registry for testing that implements IRegistry interface
contract MockRegistry is IRegistry {
    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    mapping(address => bool) public whitelistedTargets;
    mapping(address => mapping(address => mapping(bytes4 => bool))) public allowed;

    /* ///////////////////////////////////////////////////////////////
                              WHITELIST
    ///////////////////////////////////////////////////////////////*/

    function whitelistTarget(address _target) external {
        whitelistedTargets[_target] = true;
    }

    function removeTarget(address _target) external {
        whitelistedTargets[_target] = false;
    }

    function allow(address adapter, address target, bytes4 selector, bool value) external {
        allowed[adapter][target][selector] = value;
    }

    /* ///////////////////////////////////////////////////////////////
                              AUTHORIZATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRegistry
    function authorizeAdapterCall(address, bytes4, bytes calldata) external pure override {
        // Always allow for testing - override with allow() for specific restrictions
    }

    /// @inheritdoc IRegistry
    function isAdapterSelectorAllowed(address adapter, address target, bytes4 selector)
        external
        view
        override
        returns (bool)
    {
        // Check specific allowance first, then fall back to whitelist
        if (allowed[adapter][target][selector]) {
            return true;
        }
        return whitelistedTargets[target];
    }

    function isWhitelisted(address _target) external view returns (bool _isWhitelisted) {
        return whitelistedTargets[_target];
    }
}
