// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IBuyCallback, ISellCallback } from "metawallet/src/interfaces/IMidnightCallbacks.sol";

interface IMidnightModule is IBuyCallback, ISellCallback {
    struct BuyCallbackData {
        bytes32 expectedMarketId;
        uint256 minFinalLoanTokenBalance;
    }

    struct SellCallbackData {
        bytes32 expectedMarketId;
        address expectedReceiver;
    }

    struct LiquidationStep {
        address target;
        bytes callData;
        uint256 amountPlaceholderOffset;
        uint256 maxLiquidationAmount;
        uint256 minOutputAmount;
        address expectedOutputToken;
        bool enabled;
    }

    event MidnightConfigUpdated(address indexed admin, address indexed midnight);
    event IdleLiquidityCapUpdated(address indexed admin, address indexed loanToken, uint256 cap);
    event LiquidationQueueUpdated(address indexed admin, address indexed loanToken, uint256 length);
    event LiquidationQueueCleared(address indexed admin, address indexed loanToken);
    event LoanTokenFunded(
        address indexed loanToken, uint256 requestedAssets, uint256 idleUsed, uint256 liquidatedAssets
    );
    event LiquidationStepExecuted(
        address indexed loanToken, uint256 indexed index, address indexed target, uint256 amountIn, uint256 amountOut
    );
    event BuyCallback(
        bytes32 indexed marketId, address indexed buyer, address indexed loanToken, uint256 buyerAssets, uint256 units
    );
    event SellCallback(
        bytes32 indexed marketId, address indexed seller, address indexed receiver, uint256 sellerAssets, uint256 units
    );

    function setMidnightConfig(address midnight) external;
    function setIdleLiquidityCap(address loanToken, uint256 cap) external;
    function idleLiquidityCap(address loanToken) external view returns (uint256 cap);
    function setLiquidationQueue(address loanToken, LiquidationStep[] calldata steps) external;
    function clearLiquidationQueue(address loanToken) external;
    function liquidationQueue(address loanToken, uint256 index) external view returns (LiquidationStep memory step);
    function liquidationQueueLength(address loanToken) external view returns (uint256 length);
}
