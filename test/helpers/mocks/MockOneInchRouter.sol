// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    I1InchAggregationRouterV6,
    IAggregationExecutor
} from "metawallet/src/interfaces/I1InchAggregationRouterV6.sol";

/// @title MockOneInchRouter
/// @notice Mock of 1inch Aggregation Router V6 for local tests.
/// @dev Implements only the single V6 GenericRouter entry point the hook supports:
///      `swap(IAggregationExecutor, SwapDescription, bytes)`. No legacy 5-param
///      swap, no unoswap, no RFQ — scope is GenericRouter.swap only (matches the
///      production hook's support matrix). See
///      docs/superpowers/plans/2026-04-22-oneinch-typed-build.md for rationale.
contract MockOneInchRouter {
    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Native ETH sentinel address used by 1inch
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Exchange rate multiplier (scaled by 1e18)
    /// @dev Default is 1e18 (1:1 exchange rate)
    uint256 public exchangeRate = 1e18;

    /// @notice Decimal adjustment for different token decimals
    uint256 public decimalAdjustment = 1e12; // Default: USDC (6) -> WETH (18)

    /* ///////////////////////////////////////////////////////////////
                              CONFIGURATION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Set the exchange rate for swaps
    /// @param _rate The new exchange rate (scaled by 1e18)
    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    /// @notice Set the decimal adjustment
    /// @param _adjustment The decimal adjustment factor
    function setDecimalAdjustment(uint256 _adjustment) external {
        decimalAdjustment = _adjustment;
    }

    /* ///////////////////////////////////////////////////////////////
                              SWAP FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice V6-shaped swap matching the real 1inch Aggregation Router V6 signature.
    /// @dev Ignores executor and data — uses exchangeRate/decimalAdjustment so tests
    ///      can dial the output rate. desc.srcToken / desc.dstToken are typed IERC20
    ///      matching the verified V6 struct; cast to address explicitly when
    ///      comparing sentinels.
    function swap(
        IAggregationExecutor executor,
        I1InchAggregationRouterV6.SwapDescription calldata desc,
        bytes calldata data
    )
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount)
    {
        // Silence unused
        executor;
        data;

        uint256 actualAmount = desc.amount;

        // Native ETH path: msg.value is the source
        if (address(desc.srcToken) == NATIVE_ETH) {
            actualAmount = msg.value;
            require(actualAmount > 0, "No ETH sent");
        } else {
            require(desc.srcToken.transferFrom(msg.sender, address(this), actualAmount), "Transfer failed");
        }

        spentAmount = actualAmount;

        returnAmount = (actualAmount * exchangeRate * decimalAdjustment) / 1e18;

        require(returnAmount >= desc.minReturnAmount, "Insufficient return amount");

        require(desc.dstToken.transfer(desc.dstReceiver, returnAmount), "Transfer failed");
    }

    /* ///////////////////////////////////////////////////////////////
                              HELPER FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Encode V6 swap calldata for tests that want to double-check the selector
    function encodeSwapV6Calldata(
        IAggregationExecutor executor,
        I1InchAggregationRouterV6.SwapDescription calldata desc,
        bytes calldata data
    )
        external
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(I1InchAggregationRouterV6.swap, (executor, desc, data));
    }

    /// @notice Receive function to accept ETH
    receive() external payable { }
}
