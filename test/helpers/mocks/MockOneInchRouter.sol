// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";

/// @title MockOneInchRouter
/// @notice Mock contract simulating 1inch Aggregation Router behavior for testing
/// @dev Implements a simple swap function that transfers tokens at a configurable rate
contract MockOneInchRouter {
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

    /// @notice Mock swap function simulating 1inch router behavior
    /// @param srcToken The source token to swap from
    /// @param dstToken The destination token to swap to
    /// @param amount The amount of source tokens to swap (0 = use sender's balance)
    /// @param minReturn The minimum amount of destination tokens expected
    /// @param receiver The address to receive the swapped tokens
    /// @return returnAmount The amount of destination tokens received
    function swap(
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn,
        address receiver
    )
        external
        returns (uint256 returnAmount)
    {
        // If amount is 0, use the sender's entire balance of srcToken
        uint256 actualAmount = amount;
        if (actualAmount == 0) {
            actualAmount = IERC20(srcToken).balanceOf(msg.sender);
        }

        // Transfer source tokens from sender
        IERC20(srcToken).transferFrom(msg.sender, address(this), actualAmount);

        // Calculate output amount based on exchange rate
        returnAmount = (actualAmount * exchangeRate * decimalAdjustment) / 1e18;

        // Check minimum return
        require(returnAmount >= minReturn, "Insufficient return amount");

        // Transfer destination tokens to receiver
        IERC20(dstToken).transfer(receiver, returnAmount);
    }

    /// @notice Alternative swap function with different parameter order (matching 1inch v5 style)
    /// @param srcToken The source token to swap from
    /// @param dstToken The destination token to swap to
    /// @param srcReceiver The address to receive source tokens (typically this contract)
    /// @param dstReceiver The address to receive destination tokens
    /// @param amount The amount of source tokens to swap
    /// @param minReturnAmount The minimum amount of destination tokens expected
    /// @param flags Flags for the swap (ignored in mock)
    /// @return returnAmount The amount of destination tokens received
    /// @return spentAmount The amount of source tokens spent
    function swapV5(
        address srcToken,
        address dstToken,
        address srcReceiver,
        address dstReceiver,
        uint256 amount,
        uint256 minReturnAmount,
        uint256 flags
    )
        external
        returns (uint256 returnAmount, uint256 spentAmount)
    {
        // Silence unused variable warning
        srcReceiver;
        flags;

        // Transfer source tokens from sender
        IERC20(srcToken).transferFrom(msg.sender, address(this), amount);
        spentAmount = amount;

        // Calculate output amount based on exchange rate
        returnAmount = (amount * exchangeRate * decimalAdjustment) / 1e18;

        // Check minimum return
        require(returnAmount >= minReturnAmount, "Insufficient return amount");

        // Transfer destination tokens to receiver
        IERC20(dstToken).transfer(dstReceiver, returnAmount);
    }

    /// @notice Simple unoswap function (single DEX swap)
    /// @param srcToken The source token to swap from
    /// @param amount The amount of source tokens to swap
    /// @param minReturn The minimum amount of destination tokens expected
    /// @param dstToken The destination token (encoded in pools for real 1inch)
    /// @return returnAmount The amount of destination tokens received
    function unoswap(
        address srcToken,
        uint256 amount,
        uint256 minReturn,
        address dstToken
    )
        external
        returns (uint256 returnAmount)
    {
        // Transfer source tokens from sender
        IERC20(srcToken).transferFrom(msg.sender, address(this), amount);

        // Calculate output amount based on exchange rate
        returnAmount = (amount * exchangeRate * decimalAdjustment) / 1e18;

        // Check minimum return
        require(returnAmount >= minReturn, "Insufficient return amount");

        // Transfer destination tokens to sender (typical unoswap behavior)
        IERC20(dstToken).transfer(msg.sender, returnAmount);
    }

    /* ///////////////////////////////////////////////////////////////
                              HELPER FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Encode swap calldata for testing
    /// @param srcToken The source token to swap from
    /// @param dstToken The destination token to swap to
    /// @param amount The amount of source tokens to swap
    /// @param minReturn The minimum amount of destination tokens expected
    /// @param receiver The address to receive the swapped tokens
    /// @return calldata_ The encoded calldata for the swap function
    function encodeSwapCalldata(
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn,
        address receiver
    )
        external
        pure
        returns (bytes memory calldata_)
    {
        return abi.encodeWithSelector(this.swap.selector, srcToken, dstToken, amount, minReturn, receiver);
    }

    /// @notice Receive function to accept ETH
    receive() external payable { }
}
