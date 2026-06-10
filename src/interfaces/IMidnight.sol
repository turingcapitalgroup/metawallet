// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Market {
    address loanToken;
    CollateralParams[] collateralParams;
    uint256 maturity;
    uint256 rcfThreshold;
    address enterGate;
    address liquidatorGate;
}

struct CollateralParams {
    address token;
    uint256 lltv;
    uint256 maxLif;
    address oracle;
}

struct Offer {
    Market market;
    bool buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool reduceOnly;
    uint256 maxUnits;
    uint256 maxAssets;
}

interface IMidnight {
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    )
        external
        returns (uint256 buyerAssets, uint256 sellerAssets);

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    function setConsumed(bytes32 group, uint256 amount, address onBehalf) external;

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

    function toId(Market memory market) external view returns (bytes32);
}
