// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @dev Morpho Blue market identifier type
type Id is bytes32;

/// @dev Parameters that identify a Morpho Blue market
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @dev Market state stored by Morpho Blue for each market
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

/// @title IMorpho
/// @notice Minimal interface for Morpho Blue core operations (supply and withdraw)
/// @dev Based on Morpho Blue deployed at 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
interface IMorpho {
    /// @notice Supplies assets to a Morpho Blue market
    /// @param marketParams The market to supply to
    /// @param assets The amount of assets to supply (set to 0 if using shares)
    /// @param shares The amount of shares to mint (set to 0 if using assets)
    /// @param onBehalf The address that will own the supply position
    /// @param data Arbitrary data to pass to the onMorphoSupply callback (empty if no callback)
    /// @return assetsSupplied The amount of assets actually supplied
    /// @return sharesSupplied The amount of shares actually minted
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    )
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @notice Withdraws assets from a Morpho Blue market
    /// @param marketParams The market to withdraw from
    /// @param assets The amount of assets to withdraw (set to 0 if using shares)
    /// @param shares The amount of shares to burn (set to 0 if using assets)
    /// @param onBehalf The address whose position to withdraw from
    /// @param receiver The address that receives the withdrawn assets
    /// @return assetsWithdrawn The amount of assets actually withdrawn
    /// @return sharesWithdrawn The amount of shares actually burned
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    )
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    /// @notice Sets authorization for an address to act on behalf of the caller
    /// @param authorized The address to authorize or deauthorize
    /// @param newIsAuthorized Whether to authorize or deauthorize
    function setAuthorization(address authorized, bool newIsAuthorized) external;

    /// @notice Returns the market state for a given market identifier
    /// @param id The market identifier
    /// @return m The market state
    function market(Id id) external view returns (Market memory m);

    /// @notice Accrues interest for a given market
    /// @param marketParams The market parameters
    function accrueInterest(MarketParams memory marketParams) external;

    /// @notice Returns the position of a user in a market
    /// @param id The market identifier
    /// @param user The user address
    /// @return supplyShares The user's supply shares
    /// @return borrowShares The user's borrow shares
    /// @return collateral The user's collateral amount
    function position(
        Id id,
        address user
    )
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}
