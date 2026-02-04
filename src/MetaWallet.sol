// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// External Libraries
import { Execution, IRegistry, LibCall, MinimalSmartAccount } from "minimal-smart-account/MinimalSmartAccount.sol";

// Local Contracts
import { HookExecution, IHookExecution } from "./HookExecution.sol";
import { MultiFacetProxy } from "kam/base/MultiFacetProxy.sol";

/// @title MetaWallet
/// @notice Minimal smart wallet with advanced multi-hook support
/// @dev HookExecution can chain together, with each hook's output feeding into the next
contract MetaWallet is MinimalSmartAccount, HookExecution, MultiFacetProxy {
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
    function executeWithHookExecution(HookExecution[] calldata _hookExecutions)
        external
        returns (bytes[] memory _results)
    {
        _authorizeExecute(msg.sender);
        return _executeHookExecution(_hookExecutions);
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

            bytes memory _callData = _executions[_i].callData;

            bytes4 _functionSig;
            bytes memory _params;

            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                _functionSig := mload(add(_callData, 32))
            }

            if (_callData.length > 4) {
                uint256 _paramsLength = _callData.length - 4;
                _params = new bytes(_paramsLength);

                // solhint-disable-next-line no-inline-assembly
                assembly ("memory-safe") {
                    let _src := add(add(_callData, 32), 4)
                    let _dst := add(_params, 32)

                    let _fullWords := div(_paramsLength, 32)
                    for { let _j := 0 } lt(_j, _fullWords) { _j := add(_j, 1) } {
                        mstore(add(_dst, mul(_j, 32)), mload(add(_src, mul(_j, 32))))
                    }

                    let _remaining := mod(_paramsLength, 32)
                    if _remaining {
                        let _mask := not(sub(shl(mul(sub(32, _remaining), 8), 1), 1))
                        let _off := mul(_fullWords, 32)
                        mstore(add(_dst, _off), and(mload(add(_src, _off)), _mask))
                    }
                }
            } else {
                _params = new bytes(0);
            }

            _registry.authorizeCall(_executions[_i].target, _functionSig, _params);
            _results[_i] = _executions[_i].target.callContract(_executions[_i].value, _callData);

            emit Executed($.nonce, msg.sender, _executions[_i].target, _callData, _executions[_i].value, _results[_i]);
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
