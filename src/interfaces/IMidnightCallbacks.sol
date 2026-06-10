// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Market } from "metawallet/src/interfaces/IMidnight.sol";

interface IBuyCallback {
    function onBuy(
        bytes32 id,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes memory data
    )
        external
        returns (bytes32);
}

interface ISellCallback {
    function onSell(
        bytes32 id,
        Market memory market,
        uint256 sellerAssets,
        uint256 units,
        uint256 pendingFeeDecrease,
        address seller,
        address receiver,
        bytes memory data
    )
        external
        returns (bytes32);
}
