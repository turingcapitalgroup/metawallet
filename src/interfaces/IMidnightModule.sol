// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IBuyCallback, ISellCallback } from "metawallet/src/interfaces/IMidnightCallbacks.sol";

interface IMidnightModule is IBuyCallback, ISellCallback {
    enum WithdrawalStepKind {
        Disabled,
        Adapter,
        RawCall
    }

    struct BuyCallbackData {
        bytes32 expectedMarketId;
        bytes32 withdrawalQueueId;
        uint256 minFinalLoanTokenBalance;
    }

    struct SellCallbackData {
        bytes32 expectedMarketId;
        address expectedReceiver;
        uint256 minFinalLoanTokenBalance;
    }

    struct WithdrawalStep {
        WithdrawalStepKind kind;
        address target;
        uint256 value;
        bytes callData;
        uint256 amountPlaceholderOffset;
        uint256 maxWithdrawAssets;
        uint256 minLoanTokenOut;
        address expectedOutputToken;
    }

    event MidnightConfigUpdated(address indexed admin, address indexed midnight);
    event IdleLiquidityCapUpdated(address indexed admin, address indexed loanToken, uint256 cap);
    event WithdrawalQueueUpdated(
        address indexed admin, bytes32 indexed queueId, address indexed loanToken, uint256 length
    );
    event WithdrawalQueueCleared(address indexed admin, bytes32 indexed queueId);
    event LoanTokenFunded(
        address indexed loanToken, uint256 requestedAssets, uint256 idleUsed, uint256 liquidatedAssets
    );
    event WithdrawalStepExecuted(
        bytes32 indexed queueId,
        address indexed loanToken,
        uint256 indexed index,
        address target,
        uint256 amountIn,
        uint256 amountOut
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
    function setWithdrawalQueue(bytes32 queueId, address loanToken, WithdrawalStep[] calldata steps) external;
    function clearWithdrawalQueue(bytes32 queueId) external;
    function withdrawalQueue(bytes32 queueId, uint256 index) external view returns (WithdrawalStep memory step);
    function withdrawalQueueLength(bytes32 queueId) external view returns (uint256 length);
    function loanTokenQueueId(address loanToken) external pure returns (bytes32 queueId);
}
