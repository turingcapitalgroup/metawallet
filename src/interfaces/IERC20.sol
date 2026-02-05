// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC20
/// @notice Minimal ERC-20 token interface
interface IERC20 {
    /// @notice Emitted on token transfer
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted on approval change
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Returns the total token supply
    /// @return Total number of tokens in existence
    function totalSupply() external view returns (uint256);
    /// @notice Returns the balance of an account
    /// @param account Address to query the balance of
    /// @return Token balance of the account
    function balanceOf(address account) external view returns (uint256);
    /// @notice Transfers tokens to a recipient
    /// @param to Address of the recipient
    /// @param amount Number of tokens to transfer
    /// @return True if the transfer succeeded
    function transfer(address to, uint256 amount) external returns (bool);
    /// @notice Returns the remaining allowance for a spender
    /// @param owner Address of the token owner
    /// @param spender Address of the approved spender
    /// @return Remaining number of tokens the spender can transfer
    function allowance(address owner, address spender) external view returns (uint256);
    /// @notice Approves a spender to spend tokens
    /// @param spender Address authorized to spend tokens
    /// @param amount Maximum number of tokens the spender can transfer
    /// @return True if the approval succeeded
    function approve(address spender, uint256 amount) external returns (bool);
    /// @notice Transfers tokens from one address to another using allowance
    /// @param from Address to transfer tokens from
    /// @param to Address to transfer tokens to
    /// @param amount Number of tokens to transfer
    /// @return True if the transfer succeeded
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
