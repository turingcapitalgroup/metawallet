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
