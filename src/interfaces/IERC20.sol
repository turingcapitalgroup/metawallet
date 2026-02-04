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
    function totalSupply() external view returns (uint256);
    /// @notice Returns the balance of an account
    function balanceOf(address account) external view returns (uint256);
    /// @notice Transfers tokens to a recipient
    function transfer(address to, uint256 amount) external returns (bool);
    /// @notice Returns the remaining allowance for a spender
    function allowance(address owner, address spender) external view returns (uint256);
    /// @notice Approves a spender to spend tokens
    function approve(address spender, uint256 amount) external returns (bool);
    /// @notice Transfers tokens from one address to another using allowance
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
