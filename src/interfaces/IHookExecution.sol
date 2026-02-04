// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IHookExecution {
    /* //////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a hook is installed
    event HookInstalled(bytes32 indexed hookId, address indexed hook);
    /// @notice Emitted when a hook is uninstalled
    event HookUninstalled(bytes32 indexed hookId, address indexed hook);
    /// @notice Emitted when hook execution begins
    event HookExecutionStarted(bytes32 indexed hookId, address indexed hook);
    /// @notice Emitted when hook execution completes
    event HookExecutionCompleted(bytes32 indexed hookId, address indexed hook);

    /// @notice Configuration for a hook execution
    /// @param hookId Unique identifier for the hook
    /// @param data Hook-specific configuration data
    struct HookExecution {
        bytes32 hookId;
        bytes data;
    }

    /// @notice Install a hook with a unique identifier
    /// @param hookId Unique identifier for the hook (e.g., keccak256("deposit.erc4626"))
    /// @param hookAddress Address of the hook contract
    function installHook(bytes32 hookId, address hookAddress) external;

    /// @notice Uninstall a hook
    /// @param hookId Identifier of the hook to uninstall
    function uninstallHook(bytes32 hookId) external;

    /// @notice Execute a chain of hooks
    /// @dev Each hook builds its own execution logic, and hooks can chain together
    /// @param hookExecutions Array of hook executions to execute in sequence
    /// @return Final execution results
    function executeWithHookExecution(HookExecution[] calldata hookExecutions) external returns (bytes[] memory);

    /// @notice Get a hook address by identifier (external)
    /// @param hookId The hook identifier
    /// @return The hook address (address(0) if not installed)
    function getHook(bytes32 hookId) external view returns (address);

    /// @notice Get all installed hook identifiers (external)
    /// @return Array of hook identifiers
    function getInstalledHooks() external view returns (bytes32[] memory);
}
