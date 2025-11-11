// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { HookExecution, IHookExecution } from "./HookExecution.sol";
import { MultiFacetProxy } from "kam/base/MultiFacetProxy.sol";
import { Execution, IRegistry, LibCall, MinimalSmartAccount } from "minimal-smart-account/MinimalSmartAccount.sol";

/// @title MetaWallet
/// @notice ERC7579 wallet with advanced multi-hook support
/// @dev HookExecution can chain together, with each hook's output feeding into the next
contract MetaWallet is MinimalSmartAccount, HookExecution, MultiFacetProxy {
    using LibCall for address;

    /* ///////////////////////////////////////////////////////////////
                         HOOK MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookExecution
    function installHook(bytes32 hookId, address hookAddress) external {
        _checkRoles(ADMIN_ROLE);
        _installHook(hookId, hookAddress);
    }

    /// @inheritdoc IHookExecution
    function uninstallHook(bytes32 hookId) external {
        _checkRoles(ADMIN_ROLE);
        _uninstallHook(hookId);
    }

    /* ///////////////////////////////////////////////////////////////
                        HOOK-BASED EXECUTION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookExecution
    function executeWithHookExecution(HookExecution[] calldata hookExecutions) external returns (bytes[] memory) {
        _authorizeExecute(msg.sender);
        return _executeHookExecution(hookExecutions);
    }

    /* ///////////////////////////////////////////////////////////////
                     HOOKS IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Execute the operations (implementation for HookExecution abstract contract)
    /// @dev Uses the MinimalSmartAccount execution logic with registry authorization
    /// @param executions Array of executions to perform
    /// @return results Results from each execution
    function _executeOperations(Execution[] memory executions) internal override returns (bytes[] memory results) {
        MinimalAccountStorage storage $ = _getMinimalAccountStorage();
        IRegistry _registry = $.registry;

        uint256 length = executions.length;
        results = new bytes[](length);

        for (uint256 i = 0; i < length; ++i) {
            ++$.nonce;

            bytes memory callData = executions[i].callData;

            // Extract selector and parameters
            bytes4 functionSig;
            bytes memory params;

            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Load function selector (first 4 bytes)
                functionSig := mload(add(callData, 32))
            }

            // Extract parameters if callData has more than selector
            if (callData.length > 4) {
                uint256 paramsLength = callData.length - 4;
                params = new bytes(paramsLength);

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    // Copy from callData[4:] to params
                    let src := add(add(callData, 32), 4) // callData start + length slot + 4 bytes
                    let dst := add(params, 32) // params start + length slot

                    // Copy in 32-byte chunks
                    let fullWords := div(paramsLength, 32)
                    for { let j := 0 } lt(j, fullWords) { j := add(j, 1) } {
                        mstore(add(dst, mul(j, 32)), mload(add(src, mul(j, 32))))
                    }

                    // Copy remaining bytes
                    let remaining := mod(paramsLength, 32)
                    if remaining {
                        let mask := sub(shl(mul(remaining, 8), 1), 1)
                        let srcWord := and(mload(add(src, mul(fullWords, 32))), mask)
                        let dstWord := and(mload(add(dst, mul(fullWords, 32))), not(mask))
                        mstore(add(dst, mul(fullWords, 32)), or(srcWord, dstWord))
                    }
                }
            } else {
                params = new bytes(0);
            }

            // Validate through registry
            _registry.authorizeAdapterCall(executions[i].target, functionSig, params);

            // Execute call
            results[i] = executions[i].target.callContract(executions[i].value, callData);

            emit Executed($.nonce, msg.sender, executions[i].target, callData, executions[i].value, results[i]);
        }
    }

    /* ///////////////////////////////////////////////////////////////
                          AUTHORIZATION
    ///////////////////////////////////////////////////////////////*/

    /// @dev Authorize the sender to modify functions
    function _authorizeModifyFunctions(address sender) internal override {
        _checkRoles(ADMIN_ROLE);
    }
}
