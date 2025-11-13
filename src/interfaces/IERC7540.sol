// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC4626.sol";

/**
 * @title IERC7540
 * @dev Interface for Asynchronous Tokenized Vaults
 * @notice This interface extends ERC-4626 to support asynchronous deposit and redemption requests
 */
interface IERC7540 is IERC4626 {
    /**
     * @dev Emitted when a deposit request is made
     * @param controller The address that controls the request
     * @param owner The address that owns the assets
     * @param requestId The unique identifier for the request
     * @param sender The address that initiated the request
     * @param assets The amount of assets requested for deposit
     */
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /**
     * @dev Emitted when a redemption request is made
     * @param controller The address that controls the request
     * @param owner The address that owns the shares
     * @param requestId The unique identifier for the request
     * @param sender The address that initiated the request
     * @param shares The amount of shares requested for redemption
     */
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /**
     * @dev Request a deposit of assets into the vault
     * @param assets The amount of assets to deposit
     * @param controller The address that will control the request
     * @param owner The address that owns the assets
     * @return requestId The unique identifier for the deposit request
     */
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /**
     * @dev Request a redemption of shares from the vault
     * @param shares The amount of shares to redeem
     * @param controller The address that will control the request
     * @param owner The address that owns the shares
     * @return requestId The unique identifier for the redemption request
     */
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /**
     * @dev Returns the amount of requested assets pending for a controller
     * @param controller The address to check
     * @return assets The amount of assets pending
     */
    function pendingDepositRequest(address controller) external view returns (uint256 assets);

    /**
     * @dev Returns the amount of requested assets claimable for a controller
     * @param controller The address to check
     * @return assets The amount of assets claimable
     */
    function claimableDepositRequest(address controller) external view returns (uint256 assets);

    /**
     * @dev Returns the amount of requested shares pending for a controller
     * @param controller The address to check
     * @return shares The amount of shares pending
     */
    function pendingRedeemRequest(address controller) external view returns (uint256 shares);

    /**
     * @dev Returns the amount of requested shares claimable for a controller
     * @param controller The address to check
     * @return shares The amount of shares claimable
     */
    function claimableRedeemRequest(address controller) external view returns (uint256 shares);

    /**
     * @dev Returns the amount of assets that can be deposited by a controller
     * @param controller The address to check
     * @return assets The maximum amount of assets that can be deposited
     */
    function maxDeposit(address controller) external view returns (uint256 assets);

    /**
     * @dev Returns the amount of shares that can be minted by a controller
     * @param controller The address to check
     * @return shares The maximum amount of shares that can be minted
     */
    function maxMint(address controller) external view returns (uint256 shares);

    /**
     * @dev Returns the amount of shares that can be redeemed by a controller
     * @param controller The address to check
     * @return shares The maximum amount of shares that can be redeemed
     */
    function maxRedeem(address controller) external view returns (uint256 shares);

    /**
     * @dev Returns the amount of assets that can be withdrawn by a controller
     * @param controller The address to check
     * @return assets The maximum amount of assets that can be withdrawn
     */
    function maxWithdraw(address controller) external view returns (uint256 assets);
}
