// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/// @title IHook
/// @notice Interface for hooks that build their own execution logic
interface IHook {
    /// @notice Build the execution array for this hook
    /// @param previousHook The previous hook in the chain (address(0) if first)
    /// @param data Hook-specific configuration data
    /// @return executions Array of executions including preHook, hook logic, and postHook
    function buildExecutions(
        address previousHook,
        bytes calldata data
    )
        external
        view
        returns (Execution[] memory executions);

    /// @notice Set the execution context for this hook
    function initializeHookContext() external;

    /// @notice Reset the execution state after completion
    function finalizeHookContext() external;
}
