// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHookResult
/// @notice Interface for hooks that produce outputs consumable by other hooks
interface IHookResult {
    /// @notice Get the output amount from this hook's execution
    /// @return The output amount
    function getOutputAmount() external view returns (uint256);
}
