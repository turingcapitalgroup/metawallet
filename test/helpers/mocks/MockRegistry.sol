// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockRegistry {
    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    mapping(address => bool) public whitelistedTargets;

    /* ///////////////////////////////////////////////////////////////
                              WHITELIST
    ///////////////////////////////////////////////////////////////*/

    function whitelistTarget(address _target) external {
        whitelistedTargets[_target] = true;
    }

    function removeTarget(address _target) external {
        whitelistedTargets[_target] = false;
    }

    /* ///////////////////////////////////////////////////////////////
                              AUTHORIZATION
    ///////////////////////////////////////////////////////////////*/

    function authorizeAdapterCall(address _target, bytes4, bytes memory) external view {
        require(whitelistedTargets[_target], "Target not whitelisted");
        // In production, this would do more sophisticated checks
        // For testing, we just check if target is whitelisted
    }

    function isWhitelisted(address _target) external view returns (bool _isWhitelisted) {
        return whitelistedTargets[_target];
    }
}
