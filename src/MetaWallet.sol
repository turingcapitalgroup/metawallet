// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// External Libraries
import { Execution, IRegistry, LibCall, MinimalSmartAccount } from "minimal-smart-account/MinimalSmartAccount.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

// Local Contracts
import { HookExecution, IHookExecution } from "./HookExecution.sol";
import { HOOKEXECUTION_INVALID_NONCE } from "./errors/Errors.sol";
import { MultiFacetProxy } from "kam/base/MultiFacetProxy.sol";

/// @title MetaWallet
/// @notice Minimal smart wallet with advanced multi-hook support
/// @dev HookExecution can chain together, with each hook's output feeding into the next
contract MetaWallet is MinimalSmartAccount, HookExecution, MultiFacetProxy, ReentrancyGuard {
    using LibCall for address;

    /* ///////////////////////////////////////////////////////////////
                          INTERNAL CHECKS
    ///////////////////////////////////////////////////////////////*/

    function _checkAdminRole() internal view {
        _checkRoles(ADMIN_ROLE);
    }

    /* ///////////////////////////////////////////////////////////////
                         HOOK MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookExecution
    function installHook(bytes32 _hookId, address _hookAddress) external {
        _checkAdminRole();
        _installHook(_hookId, _hookAddress);
    }

    /// @inheritdoc IHookExecution
    function uninstallHook(bytes32 _hookId) external {
        _checkAdminRole();
        _uninstallHook(_hookId);
    }

    /* ///////////////////////////////////////////////////////////////
                        HOOK-BASED EXECUTION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookExecution
    function executeWithHookExecution(
        uint256 _expectedNonce,
        uint256 _deadline,
        HookExecution[] calldata _hookExecutions
    )
        external
        nonReentrant
        returns (bytes[] memory _results)
    {
        _authorizeExecute(msg.sender);
        require(_getMinimalAccountStorage().nonce == _expectedNonce, HOOKEXECUTION_INVALID_NONCE);
        return _executeHookExecution(_deadline, _hookExecutions);
    }

    /* ///////////////////////////////////////////////////////////////
                     HOOKS IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Execute the operations (implementation for HookExecution abstract contract)
    /// @dev Uses the MinimalSmartAccount execution logic with registry authorization
    /// @param _executions Array of executions to perform
    /// @return _results Results from each execution
    function _executeOperations(Execution[] memory _executions) internal override returns (bytes[] memory _results) {
        MinimalAccountStorage storage $ = _getMinimalAccountStorage();
        IRegistry _registry = $.registry;

        uint256 _length = _executions.length;
        _results = new bytes[](_length);

        for (uint256 _i = 0; _i < _length; ++_i) {
            ++$.nonce;
            _results[_i] = _executeOperation($.nonce, _registry, _executions[_i]);
        }
    }

    function _executeOperation(
        uint256 _nonce,
        IRegistry _registry,
        Execution memory _execution
    )
        private
        returns (bytes memory _result)
    {
        (bytes4 _functionSig, bytes memory _params) = _callAuthorizationData(_execution.callData);

        _registry.authorizeCall(_execution.target, _functionSig, _params);
        _result = _execution.target.callContract(_execution.value, _execution.callData);

        emit Executed(_nonce, msg.sender, _execution.target, _execution.callData, _execution.value, _result);
    }

    function _callAuthorizationData(bytes memory _callData)
        private
        pure
        returns (bytes4 _functionSig, bytes memory _params)
    {
        assembly ("memory-safe") {
            _functionSig := mload(add(_callData, 32))
        }

        if (_callData.length <= 4) return (_functionSig, new bytes(0));

        uint256 _paramsLength = _callData.length - 4;
        _params = new bytes(_paramsLength);
        for (uint256 _i; _i < _paramsLength; ++_i) {
            _params[_i] = _callData[_i + 4];
        }
    }

    /* ///////////////////////////////////////////////////////////////
                          AUTHORIZATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc MultiFacetProxy
    function _authorizeModifyFunctions(address) internal view override {
        _checkAdminRole();
    }
}
