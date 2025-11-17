// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "./IERC20.sol";

/**
 * @title IERC4626
 * @dev Interface for Tokenized Vaults
 * @notice This is the base interface that ERC-7540 extends
 */
interface IERC4626 is IERC20 {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /**
     * @dev Returns the address of the underlying token
     */
    function asset() external view returns (address assetTokenAddress);

    /**
     * @dev Returns the total amount of underlying assets held by the vault
     */
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /**
     * @dev Converts asset amount to shares
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Converts shares amount to assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Returns the maximum amount of assets that can be deposited
     */
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /**
     * @dev Previews the amount of shares for a deposit
     */
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Deposits assets and mints shares to receiver
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @dev Returns the maximum amount of shares that can be minted
     */
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /**
     * @dev Previews the amount of assets needed to mint shares
     */
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Mints shares to receiver by depositing assets
     */
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /**
     * @dev Returns the maximum amount of assets that can be withdrawn
     */
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /**
     * @dev Previews the amount of shares that will be burned for a withdrawal
     */
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /**
     * @dev Withdraws assets by burning shares
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /**
     * @dev Returns the maximum amount of shares that can be redeemed
     */
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /**
     * @dev Previews the amount of assets for redeeming shares
     */
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /**
     * @dev Redeems shares for assets
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
