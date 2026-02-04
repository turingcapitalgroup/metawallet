// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "./IERC20.sol";

/// @title IERC4626
/// @notice Interface for ERC-4626 Tokenized Vaults
interface IERC4626 is IERC20 {
    /// @notice Emitted on deposit
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    /// @notice Emitted on withdrawal
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Returns the address of the underlying token
    /// @return assetTokenAddress Address of the underlying ERC-20 asset
    function asset() external view returns (address assetTokenAddress);

    /// @notice Returns the total amount of underlying assets held by the vault
    /// @return totalManagedAssets Total assets managed by the vault
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Converts asset amount to shares
    /// @param assets Amount of assets to convert
    /// @return shares Equivalent amount of shares
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts shares amount to assets
    /// @param shares Amount of shares to convert
    /// @return assets Equivalent amount of assets
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the maximum amount of assets that can be deposited
    /// @param receiver Address that would receive the shares
    /// @return maxAssets Maximum depositable asset amount
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Previews the amount of shares for a deposit
    /// @param assets Amount of assets to deposit
    /// @return shares Amount of shares that would be minted
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Deposits assets and mints shares to receiver
    /// @param assets Amount of assets to deposit
    /// @param receiver Address that receives the minted shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Returns the maximum amount of shares that can be minted
    /// @param receiver Address that would receive the shares
    /// @return maxShares Maximum mintable share amount
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Previews the amount of assets needed to mint shares
    /// @param shares Amount of shares to mint
    /// @return assets Amount of assets required
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Mints shares to receiver by depositing assets
    /// @param shares Amount of shares to mint
    /// @param receiver Address that receives the minted shares
    /// @return assets Amount of assets deposited
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Returns the maximum amount of assets that can be withdrawn
    /// @param owner Address of the share owner
    /// @return maxAssets Maximum withdrawable asset amount
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Previews the amount of shares burned for a withdrawal
    /// @param assets Amount of assets to withdraw
    /// @return shares Amount of shares that would be burned
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Withdraws assets by burning shares
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address that receives the withdrawn assets
    /// @param owner Address of the share owner
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Returns the maximum amount of shares that can be redeemed
    /// @param owner Address of the share owner
    /// @return maxShares Maximum redeemable share amount
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Previews the amount of assets for redeeming shares
    /// @param shares Amount of shares to redeem
    /// @return assets Amount of assets that would be returned
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Redeems shares for assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address that receives the redeemed assets
    /// @param owner Address of the share owner
    /// @return assets Amount of assets returned
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
