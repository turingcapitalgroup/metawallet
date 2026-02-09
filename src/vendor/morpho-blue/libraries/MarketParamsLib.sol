// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import { Id, MarketParams } from "../interfaces/IMorpho.sol";

/// @title MarketParamsLib
/// @notice Library for computing Morpho Blue market identifiers from MarketParams
library MarketParamsLib {
    /// @dev The byte length of MarketParams (5 fields x 32 bytes each)
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    /// @notice Computes the market identifier from market parameters
    /// @param marketParams The market parameters
    /// @return marketParamsId The unique market identifier
    function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId) {
        assembly ("memory-safe") {
            marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
        }
    }
}
