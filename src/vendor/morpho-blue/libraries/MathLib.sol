// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title MathLib
/// @notice Library for fixed-point arithmetic helpers used in Morpho Blue share math
library MathLib {
    /// @notice Returns (x * y) / d rounded down
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @notice Returns (x * y) / d rounded up
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }
}
