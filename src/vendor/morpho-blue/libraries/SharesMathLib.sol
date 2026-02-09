// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import { MathLib } from "./MathLib.sol";

/// @title SharesMathLib
/// @notice Library for Morpho Blue share/asset conversion with virtual shares for rounding protection
/// @dev Uses VIRTUAL_SHARES (1e6) and VIRTUAL_ASSETS (1) to prevent share inflation attacks
library SharesMathLib {
    using MathLib for uint256;

    /// @dev Virtual shares offset for rounding protection
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /// @dev Virtual assets offset for rounding protection
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Converts assets to shares, rounding down
    /// @param assets The amount of assets to convert
    /// @param totalAssets The total assets in the market
    /// @param totalShares The total shares in the market
    /// @return The corresponding amount of shares (rounded down)
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivDown(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice Converts assets to shares, rounding up
    /// @param assets The amount of assets to convert
    /// @param totalAssets The total assets in the market
    /// @param totalShares The total shares in the market
    /// @return The corresponding amount of shares (rounded up)
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivUp(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice Converts shares to assets, rounding down
    /// @param shares The amount of shares to convert
    /// @param totalAssets The total assets in the market
    /// @param totalShares The total shares in the market
    /// @return The corresponding amount of assets (rounded down)
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivDown(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice Converts shares to assets, rounding up
    /// @param shares The amount of shares to convert
    /// @param totalAssets The total assets in the market
    /// @param totalShares The total shares in the market
    /// @return The corresponding amount of assets (rounded up)
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivUp(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}
