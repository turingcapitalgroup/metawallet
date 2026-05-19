// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";

/// @title IAggregationExecutor
/// @notice Mirror of the 1inch V6 IAggregationExecutor interface
/// @dev Copied verbatim from AggregationRouterV6.mainnet.sol lines 4717-4720
///      (selector 0x4b64e492). The hook does not call this directly; the router
///      does. Defined here so consumers (hook, mock router) share one canonical
///      type.
interface IAggregationExecutor {
    /// @notice propagates information about original msg.sender and executes arbitrary data
    function execute(address msgSender) external payable returns (uint256);
}

/// @title I1InchAggregationRouterV6
/// @notice Minimal 1inch V6 Aggregation Router interface, limited to the single
///         entry point this hook supports: GenericRouter.swap.
/// @dev SwapDescription + swap() copied verbatim from AggregationRouterV6.mainnet.sol
///      lines 4738-4770 (selector 0x07ed2379). Do not reorder fields — the on-chain
///      router ABI is positional.
interface I1InchAggregationRouterV6 {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    /// @notice Performs a swap, delegating all calls encoded in `data` to `executor`.
    /// @param executor Aggregation executor that executes calls described in `data`.
    /// @param desc Typed swap description (tokens, amounts, receivers, flags).
    /// @param data Encoded calls that `executor` should execute in between of swaps.
    /// @return returnAmount Resulting token amount.
    /// @return spentAmount Source token amount.
    function swap(
        IAggregationExecutor executor,
        SwapDescription calldata desc,
        bytes calldata data
    )
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount);
}
