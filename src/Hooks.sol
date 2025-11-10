// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Execution } from "erc7579-minimal/interfaces/IERC7579Minimal.sol";

/**
 * @title IHook
 * @notice Interface for hooks that build their own execution logic
 */
interface IHook {
    enum HookType {
        NONACCOUNTING, // Hook doesn't affect accounting (e.g., logging, bridging)
        INFLOW, // Hook increases balance (e.g., deposits, minting)
        OUTFLOW // Hook decreases balance (e.g., withdrawals, burns)
    }

    /**
     * @notice Build the execution array for this hook
     * @param previousHook The previous hook in the chain (address(0) if first)
     * @param smartAccount The account executing the hook
     * @param data Hook-specific configuration data
     * @return executions Array of executions including preHook, hook logic, and postHook
     */
    function buildExecutions(address previousHook, address smartAccount, bytes calldata data)
        external
        view
        returns (Execution[] memory executions);

    /**
     * @notice Set the execution context for this hook
     * @param caller The address calling the hook
     */
    function initializeHookContext(address caller) external;

    /**
     * @notice Reset the execution state after completion
     * @param caller The address that executed the hook
     */
    function finalizeHookContext(address caller) external;

    /**
     * @notice Get the hook type
     */
    function getHookType() external view returns (HookType);

    /**
     * @notice Get the hook subtype identifier
     */
    function getHookSubtype() external view returns (bytes32);
}

/**
 * @title IHookResult
 * @notice Interface for hooks that produce outputs consumable by other hooks
 */
interface IHookResult {
    /**
     * @notice Get the output amount from this hook's execution
     * @param caller The account that executed the hook
     * @return The output amount
     */
    function getOutputAmount(address caller) external view returns (uint256);
}

/**
 * @title Hooks
 * @notice Abstract contract providing multi-hook execution capabilities
 * @dev Uses namespaced storage pattern for upgradeability (ERC-7201)
 */
abstract contract Hooks {
    /* ///////////////////////////////////////////////////////////////
                              STRUCTURES
    ///////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration for a hook execution
     * @param hookId Unique identifier for the hook
     * @param data Hook-specific configuration data
     */
    struct HookExecution {
        bytes32 hookId;
        bytes data;
    }

    /**
     * @notice Storage structure for hooks
     * @custom:storage-location erc7201:metawallet.storage.Hooks
     */
    struct HooksStorage {
        /// @notice Registry of installed hooks by identifier
        mapping(bytes32 => address) hooks;
        /// @notice Array of all installed hook identifiers for enumeration
        bytes32[] hookIds;
    }

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    // keccak256(abi.encode(uint256(keccak256("metawallet.storage.Hooks")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant HOOKS_STORAGE_LOCATION =
        0x8d3e3f6f5e5d7b8c9a2b4d1e3f5a6c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a00;

    /* ///////////////////////////////////////////////////////////////
                                EVENTS
    ///////////////////////////////////////////////////////////////*/

    event HookInstalled(bytes32 indexed hookId, address indexed hook);
    event HookUninstalled(bytes32 indexed hookId, address indexed hook);
    event HookExecutionStarted(bytes32 indexed hookId, address indexed hook);
    event HookExecutionCompleted(bytes32 indexed hookId, address indexed hook);

    /* ///////////////////////////////////////////////////////////////
                               ERRORS
    ///////////////////////////////////////////////////////////////*/

    error HookNotInstalled(bytes32 hookId);
    error HookAlreadyInstalled(bytes32 hookId);
    error InvalidHookAddress();
    error HookExecutionFailed(bytes32 hookId, string reason);
    error EmptyHookChain();

    /* ///////////////////////////////////////////////////////////////
                          STORAGE ACCESS
    ///////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the hooks storage struct
     * @return $ The hooks storage struct
     */
    function _getHooksStorage() private pure returns (HooksStorage storage $) {
        assembly {
            $.slot := HOOKS_STORAGE_LOCATION
        }
    }

    /* ///////////////////////////////////////////////////////////////
                          HOOK MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /**
     * @notice Install a hook with a unique identifier
     * @param hookId Unique identifier for the hook (e.g., keccak256("deposit.erc4626"))
     * @param hookAddress Address of the hook contract
     */
    function _installHook(bytes32 hookId, address hookAddress) internal {
        if (hookAddress == address(0)) revert InvalidHookAddress();

        HooksStorage storage $ = _getHooksStorage();
        if ($.hooks[hookId] != address(0)) revert HookAlreadyInstalled(hookId);

        $.hooks[hookId] = hookAddress;
        $.hookIds.push(hookId);

        emit HookInstalled(hookId, hookAddress);
    }

    /**
     * @notice Uninstall a hook
     * @param hookId Identifier of the hook to uninstall
     */
    function _uninstallHook(bytes32 hookId) internal {
        HooksStorage storage $ = _getHooksStorage();
        address hookAddress = $.hooks[hookId];
        if (hookAddress == address(0)) revert HookNotInstalled(hookId);

        delete $.hooks[hookId];

        // Remove from array
        bytes32[] storage hookIds = $.hookIds;
        for (uint256 i = 0; i < hookIds.length; i++) {
            if (hookIds[i] == hookId) {
                hookIds[i] = hookIds[hookIds.length - 1];
                hookIds.pop();
                break;
            }
        }

        emit HookUninstalled(hookId, hookAddress);
    }

    /**
     * @notice Get a hook address by identifier
     * @param hookId The hook identifier
     * @return The hook address (address(0) if not installed)
     */
    function _getHook(bytes32 hookId) internal view returns (address) {
        HooksStorage storage $ = _getHooksStorage();
        return $.hooks[hookId];
    }

    /**
     * @notice Get all installed hook identifiers
     * @return Array of hook identifiers
     */
    function _getInstalledHooks() internal view returns (bytes32[] memory) {
        HooksStorage storage $ = _getHooksStorage();
        return $.hookIds;
    }

    /* ///////////////////////////////////////////////////////////////
                        HOOK EXECUTION
    ///////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a chain of hooks
     * @dev Each hook builds its own execution logic, and hooks can chain together
     * @param hookExecutions Array of hook executions to execute in sequence
     * @return results Final execution results
     */
    function _executeHooks(HookExecution[] calldata hookExecutions) internal returns (bytes[] memory results) {
        if (hookExecutions.length == 0) revert EmptyHookChain();

        // Build the complete execution sequence by chaining all hooks
        Execution[] memory allExecutions = _buildExecutionChain(hookExecutions);

        // Execute all operations in sequence
        return _processHookChain(allExecutions, hookExecutions);
    }

    /**
     * @notice Build the complete execution chain from all hooks
     * @dev Each hook's buildExecutions() returns [preHook, ...operations, postHook]
     */
    function _buildExecutionChain(HookExecution[] calldata hookExecutions)
        internal
        view
        returns (Execution[] memory allExecutions)
    {
        HooksStorage storage $ = _getHooksStorage();

        // First pass: count total executions needed
        uint256 totalExecutions = 0;
        for (uint256 i = 0; i < hookExecutions.length; i++) {
            address hookAddress = $.hooks[hookExecutions[i].hookId];
            if (hookAddress == address(0)) revert HookNotInstalled(hookExecutions[i].hookId);

            address previousHook = i > 0 ? $.hooks[hookExecutions[i - 1].hookId] : address(0);
            Execution[] memory hookExecs =
                IHook(hookAddress).buildExecutions(previousHook, address(this), hookExecutions[i].data);
            totalExecutions += hookExecs.length;
        }

        // Second pass: build the complete execution array
        allExecutions = new Execution[](totalExecutions);
        uint256 execIndex = 0;

        for (uint256 i = 0; i < hookExecutions.length; i++) {
            address hookAddress = $.hooks[hookExecutions[i].hookId];
            address previousHook = i > 0 ? $.hooks[hookExecutions[i - 1].hookId] : address(0);

            Execution[] memory hookExecs =
                IHook(hookAddress).buildExecutions(previousHook, address(this), hookExecutions[i].data);

            // Copy hook executions into the main array
            for (uint256 j = 0; j < hookExecs.length; j++) {
                allExecutions[execIndex++] = hookExecs[j];
            }
        }
    }

    /**
     * @notice Execute the complete hook chain
     * @dev Sets up execution context, executes all operations, and cleans up
     */
    function _processHookChain(Execution[] memory executions, HookExecution[] calldata hookExecutions)
        internal
        returns (bytes[] memory results)
    {
        HooksStorage storage $ = _getHooksStorage();

        // Set execution context for all hooks
        for (uint256 i = 0; i < hookExecutions.length; i++) {
            address hookAddress = $.hooks[hookExecutions[i].hookId];
            IHook(hookAddress).initializeHookContext(address(this));
            emit HookExecutionStarted(hookExecutions[i].hookId, hookAddress);
        }

        // Execute all operations using the implementation's _exec function
        results = _executeOperations(executions);

        // Reset execution state for all hooks
        for (uint256 i = 0; i < hookExecutions.length; i++) {
            address hookAddress = $.hooks[hookExecutions[i].hookId];
            IHook(hookAddress).finalizeHookContext(address(this));
            emit HookExecutionCompleted(hookExecutions[i].hookId, hookAddress);
        }
    }

    /**
     * @notice Execute the operations
     * @dev Must be implemented by the inheriting contract to perform actual execution
     * @param executions Array of executions to perform
     * @return results Results from each execution
     */
    function _executeOperations(Execution[] memory executions) internal virtual returns (bytes[] memory results);

    /* ///////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /**
     * @notice Get a hook address by identifier (external)
     * @param hookId The hook identifier
     * @return The hook address (address(0) if not installed)
     */
    function getHook(bytes32 hookId) external view returns (address) {
        return _getHook(hookId);
    }

    /**
     * @notice Get all installed hook identifiers (external)
     * @return Array of hook identifiers
     */
    function getInstalledHooks() external view returns (bytes32[] memory) {
        return _getInstalledHooks();
    }
}
