// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// External Libraries
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

// Local Interfaces
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { IHookExecution } from "metawallet/src/interfaces/IHookExecution.sol";

// Local Errors
import {
    HOOKEXECUTION_EMPTY_HOOK_CHAIN,
    HOOKEXECUTION_HOOK_ALREADY_INSTALLED,
    HOOKEXECUTION_HOOK_NOT_INSTALLED,
    HOOKEXECUTION_INVALID_HOOK_ADDRESS
} from "metawallet/src/errors/Errors.sol";

/// @title HookExecution
/// @notice Abstract contract providing multi-hook execution capabilities
/// @dev Uses namespaced storage pattern for upgradeability (ERC-7201)
abstract contract HookExecution is IHookExecution {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

    /* ///////////////////////////////////////////////////////////////
                              STRUCTURES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Storage structure for hooks
    /// @custom:storage-location erc7201:metawallet.storage.HookExecution
    struct HookExecutionStorage {
        /// @notice Registry of installed hooks by identifier
        mapping(bytes32 => address) hooks;
        /// @notice Array of all installed hook identifiers for enumeration
        EnumerableSetLib.Bytes32Set hookIds;
    }

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    // keccak256(abi.encode(uint256(keccak256("metawallet.storage.HookExecution")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant HOOKS_STORAGE_LOCATION =
        0x84561f583180cd92b2d787d13f2354aaa07b9087fa805467f0e3f5d2c4229100;

    /* ///////////////////////////////////////////////////////////////
                          STORAGE ACCESS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Get the hooks storage struct
    /// @return $ The hooks storage struct
    function _getHookExecutionStorage() private pure returns (HookExecutionStorage storage $) {
        assembly {
            $.slot := HOOKS_STORAGE_LOCATION
        }
    }

    /* ///////////////////////////////////////////////////////////////
                          HOOK MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Install a hook with a unique identifier
    /// @param _hookId Unique identifier for the hook (e.g., keccak256("deposit.erc4626"))
    /// @param _hookAddress Address of the hook contract
    function _installHook(bytes32 _hookId, address _hookAddress) internal {
        require(_hookAddress != address(0), HOOKEXECUTION_INVALID_HOOK_ADDRESS);

        HookExecutionStorage storage $ = _getHookExecutionStorage();
        require($.hooks[_hookId] == address(0), HOOKEXECUTION_HOOK_ALREADY_INSTALLED);

        $.hooks[_hookId] = _hookAddress;
        $.hookIds.add(_hookId);

        emit HookInstalled(_hookId, _hookAddress);
    }

    /// @notice Uninstall a hook
    /// @param _hookId Identifier of the hook to uninstall
    function _uninstallHook(bytes32 _hookId) internal {
        HookExecutionStorage storage $ = _getHookExecutionStorage();
        address _hookAddress = $.hooks[_hookId];
        require(_hookAddress != address(0), HOOKEXECUTION_HOOK_NOT_INSTALLED);

        delete $.hooks[_hookId];
        $.hookIds.remove(_hookId);

        emit HookUninstalled(_hookId, _hookAddress);
    }

    /// @notice Get a hook address by identifier
    /// @param _hookId The hook identifier
    /// @return _hookAddress The hook address (address(0) if not installed)
    function _getHook(bytes32 _hookId) internal view returns (address _hookAddress) {
        HookExecutionStorage storage $ = _getHookExecutionStorage();
        return $.hooks[_hookId];
    }

    /// @notice Get all installed hook identifiers
    /// @return _hookIds Array of hook identifiers
    function _getInstalledHooks() internal view returns (bytes32[] memory _hookIds) {
        HookExecutionStorage storage $ = _getHookExecutionStorage();
        return $.hookIds.values();
    }

    /* ///////////////////////////////////////////////////////////////
                        HOOK EXECUTION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Execute a chain of hooks
    /// @dev Each hook builds its own execution logic, and hooks can chain together
    /// @param _hookExecutions Array of hook executions to execute in sequence
    /// @return _results Final execution results
    function _executeHookExecution(HookExecution[] calldata _hookExecutions)
        internal
        returns (bytes[] memory _results)
    {
        require(_hookExecutions.length > 0, HOOKEXECUTION_EMPTY_HOOK_CHAIN);

        Execution[] memory _allExecutions = _buildExecutionChain(_hookExecutions);
        return _processHookChain(_allExecutions, _hookExecutions);
    }

    /// @notice Build the complete execution chain from all hooks
    /// @dev Single-pass: calls buildExecutions() once per hook, caches results, then flattens
    /// @param _hookExecutions Array of hook executions to build chain from
    /// @return _allExecutions Complete array of executions to perform
    function _buildExecutionChain(HookExecution[] calldata _hookExecutions)
        internal
        view
        returns (Execution[] memory _allExecutions)
    {
        HookExecutionStorage storage $ = _getHookExecutionStorage();

        uint256 _hookCount = _hookExecutions.length;
        Execution[][] memory _hookExecArrays = new Execution[][](_hookCount);
        uint256 _totalExecutions = 0;

        for (uint256 _i = 0; _i < _hookCount; _i++) {
            address _hookAddress = $.hooks[_hookExecutions[_i].hookId];
            require(_hookAddress != address(0), HOOKEXECUTION_HOOK_NOT_INSTALLED);

            address _previousHook = _i > 0 ? $.hooks[_hookExecutions[_i - 1].hookId] : address(0);
            _hookExecArrays[_i] = IHook(_hookAddress).buildExecutions(_previousHook, _hookExecutions[_i].data);
            _totalExecutions += _hookExecArrays[_i].length;
        }

        _allExecutions = new Execution[](_totalExecutions);
        uint256 _execIndex = 0;

        for (uint256 _i = 0; _i < _hookCount; _i++) {
            uint256 _len = _hookExecArrays[_i].length;
            for (uint256 _j = 0; _j < _len; _j++) {
                _allExecutions[_execIndex++] = _hookExecArrays[_i][_j];
            }
        }
    }

    /// @notice Execute the complete hook chain
    /// @dev Sets up execution context, executes all operations, and cleans up
    /// @param _executions Array of executions to perform
    /// @param _hookExecutions Array of hook execution metadata
    /// @return _results Results from each execution
    function _processHookChain(
        Execution[] memory _executions,
        HookExecution[] calldata _hookExecutions
    )
        internal
        returns (bytes[] memory _results)
    {
        HookExecutionStorage storage $ = _getHookExecutionStorage();

        for (uint256 _i = 0; _i < _hookExecutions.length; _i++) {
            address _hookAddress = $.hooks[_hookExecutions[_i].hookId];
            IHook(_hookAddress).initializeHookContext();
            emit HookExecutionStarted(_hookExecutions[_i].hookId, _hookAddress);
        }

        _results = _executeOperations(_executions);

        for (uint256 _i = 0; _i < _hookExecutions.length; _i++) {
            address _hookAddress = $.hooks[_hookExecutions[_i].hookId];
            IHook(_hookAddress).finalizeHookContext();
            emit HookExecutionCompleted(_hookExecutions[_i].hookId, _hookAddress);
        }
    }

    /// @notice Execute the operations
    /// @dev Must be implemented by the inheriting contract to perform actual execution
    /// @param _executions Array of executions to perform
    /// @return _results Results from each execution
    function _executeOperations(Execution[] memory _executions) internal virtual returns (bytes[] memory _results);

    /* ///////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookExecution
    function getHook(bytes32 _hookId) external view returns (address _hookAddress) {
        return _getHook(_hookId);
    }

    /// @inheritdoc IHookExecution
    function getInstalledHooks() external view returns (bytes32[] memory _hookIds) {
        return _getInstalledHooks();
    }
}
