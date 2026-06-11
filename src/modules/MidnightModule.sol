// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OwnableRoles } from "solady/auth/OwnableRoles.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IModule } from "kam/interfaces/modules/IModule.sol";
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IMidnight, Market } from "metawallet/src/interfaces/IMidnight.sol";
import { IMidnightModule } from "metawallet/src/interfaces/IMidnightModule.sol";
import { IStrategyLiquidationAdapter } from "metawallet/src/interfaces/IStrategyLiquidationAdapter.sol";
import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";

import {
    MIDNIGHT_INSUFFICIENT_LIQUIDITY,
    MIDNIGHT_INSUFFICIENT_STEP_OUTPUT,
    MIDNIGHT_INVALID_ADDRESS,
    MIDNIGHT_INVALID_BUYER,
    MIDNIGHT_INVALID_LIQUIDATION_STEP,
    MIDNIGHT_INVALID_LOAN_TOKEN,
    MIDNIGHT_INVALID_MARKET,
    MIDNIGHT_INVALID_PLACEHOLDER_OFFSET,
    MIDNIGHT_INVALID_RECEIVER,
    MIDNIGHT_INVALID_SELLER,
    MIDNIGHT_LIQUIDATION_CALL_FAILED,
    MIDNIGHT_NOT_CONFIGURED,
    MIDNIGHT_ONLY_MIDNIGHT
} from "metawallet/src/errors/Errors.sol";

/// @title MidnightModule
/// @notice MetaWallet facet for Morpho Midnight maker callbacks.
contract MidnightModule is IMidnightModule, OwnableRoles, IModule {
    using SafeTransferLib for address;

    uint256 public constant ADMIN_ROLE = _ROLE_0;
    uint256 public constant EXECUTOR_ROLE = _ROLE_1;

    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    struct WithdrawalQueue {
        address loanToken;
        WithdrawalStep[] steps;
    }

    struct MidnightModuleStorage {
        address midnight;
        mapping(address => uint256) idleLiquidityCaps;
        mapping(bytes32 queueId => WithdrawalQueue) withdrawalQueues;
    }

    struct MinimalAccountStorage {
        IRegistry registry;
        uint256 nonce;
        string accountId;
    }

    // keccak256(abi.encode(uint256(keccak256("metawallet.storage.MidnightModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MIDNIGHT_MODULE_STORAGE_LOCATION =
        0x54ce5ed94cda3a19891bab42322a0492c38e3b806dbd1c7f0491df287a426d00;

    // keccak256(abi.encode(uint256(keccak256("minimalaccount.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MINIMALACCOUNT_STORAGE_LOCATION =
        0x6bd7bb73346b1d329ae71e3bd6a33dda74a99b8d2b63e56995f04f7bd5013a00;

    function _getMidnightModuleStorage() internal pure returns (MidnightModuleStorage storage $) {
        bytes32 _slot = MIDNIGHT_MODULE_STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := _slot
        }
    }

    function _getMinimalAccountStorage() internal pure returns (MinimalAccountStorage storage $) {
        bytes32 _slot = MINIMALACCOUNT_STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := _slot
        }
    }

    function _checkAdminRole() internal view {
        _checkRoles(ADMIN_ROLE);
    }

    function _midnight(MidnightModuleStorage storage $) internal view returns (address _midnightAddress) {
        _midnightAddress = $.midnight;
        require(_midnightAddress != address(0), MIDNIGHT_NOT_CONFIGURED);
    }

    function setMidnightConfig(address _midnightAddress) external {
        _checkAdminRole();
        require(_midnightAddress != address(0), MIDNIGHT_INVALID_ADDRESS);

        _getMidnightModuleStorage().midnight = _midnightAddress;

        emit MidnightConfigUpdated(msg.sender, _midnightAddress);
    }

    function setIdleLiquidityCap(address _loanToken, uint256 _cap) external {
        _checkAdminRole();
        require(_loanToken != address(0), MIDNIGHT_INVALID_LOAN_TOKEN);

        _getMidnightModuleStorage().idleLiquidityCaps[_loanToken] = _cap;

        emit IdleLiquidityCapUpdated(msg.sender, _loanToken, _cap);
    }

    function idleLiquidityCap(address _loanToken) external view returns (uint256 _cap) {
        return _getMidnightModuleStorage().idleLiquidityCaps[_loanToken];
    }

    /// @notice Default withdrawal queue id for a loan token.
    function loanTokenQueueId(address _loanToken) public pure returns (bytes32 _queueId) {
        return bytes32(uint256(uint160(_loanToken)));
    }

    function setWithdrawalQueue(bytes32 _queueId, address _loanToken, WithdrawalStep[] calldata _steps) external {
        _checkAdminRole();
        require(_queueId != bytes32(0), MIDNIGHT_INVALID_LIQUIDATION_STEP);
        require(_loanToken != address(0), MIDNIGHT_INVALID_LOAN_TOKEN);

        MidnightModuleStorage storage $ = _getMidnightModuleStorage();
        WithdrawalQueue storage _queue = $.withdrawalQueues[_queueId];
        delete $.withdrawalQueues[_queueId];
        _queue.loanToken = _loanToken;

        uint256 _length = _steps.length;
        for (uint256 _i; _i < _length; ++_i) {
            WithdrawalStep calldata _step = _steps[_i];
            _validateWithdrawalStep(_loanToken, _step);
            _queue.steps
                .push(
                    WithdrawalStep({
                        kind: _step.kind,
                        target: _step.target,
                        value: _step.value,
                        callData: _step.callData,
                        amountPlaceholderOffset: _step.amountPlaceholderOffset,
                        maxWithdrawAssets: _step.maxWithdrawAssets,
                        minLoanTokenOut: _step.minLoanTokenOut,
                        expectedOutputToken: _step.expectedOutputToken
                    })
                );
        }

        emit WithdrawalQueueUpdated(msg.sender, _queueId, _loanToken, _length);
    }

    function clearWithdrawalQueue(bytes32 _queueId) external {
        _checkAdminRole();
        require(_queueId != bytes32(0), MIDNIGHT_INVALID_LIQUIDATION_STEP);

        delete _getMidnightModuleStorage().withdrawalQueues[_queueId];

        emit WithdrawalQueueCleared(msg.sender, _queueId);
    }

    function withdrawalQueue(bytes32 _queueId, uint256 _index) external view returns (WithdrawalStep memory _step) {
        return _getMidnightModuleStorage().withdrawalQueues[_queueId].steps[_index];
    }

    function withdrawalQueueLength(bytes32 _queueId) external view returns (uint256 _length) {
        return _getMidnightModuleStorage().withdrawalQueues[_queueId].steps.length;
    }

    function onBuy(
        bytes32 _id,
        Market memory _market,
        uint256 _buyerAssets,
        uint256 _units,
        uint256 _pendingFeeIncrease,
        address _buyer,
        bytes memory _data
    )
        external
        returns (bytes32)
    {
        _pendingFeeIncrease;
        MidnightModuleStorage storage $ = _getMidnightModuleStorage();
        address _midnightAddress = _midnight($);
        require(msg.sender == _midnightAddress, MIDNIGHT_ONLY_MIDNIGHT);
        require(_buyer == address(this), MIDNIGHT_INVALID_BUYER);
        require(_market.loanToken != address(0), MIDNIGHT_INVALID_LOAN_TOKEN);
        require(_id == _marketToId(_midnightAddress, _market), MIDNIGHT_INVALID_MARKET);

        BuyCallbackData memory _callbackData;
        if (_data.length != 0) {
            _callbackData = abi.decode(_data, (BuyCallbackData));
            require(
                _callbackData.expectedMarketId == bytes32(0) || _callbackData.expectedMarketId == _id,
                MIDNIGHT_INVALID_MARKET
            );
        }

        bytes32 _queueId = _callbackData.withdrawalQueueId == bytes32(0)
            ? loanTokenQueueId(_market.loanToken)
            : _callbackData.withdrawalQueueId;

        _fundLoanToken($, _queueId, _market.loanToken, _buyerAssets, _callbackData.minFinalLoanTokenBalance);
        _market.loanToken.safeApproveWithRetry(_midnightAddress, _buyerAssets);

        emit BuyCallback(_id, _buyer, _market.loanToken, _buyerAssets, _units);
        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32 _id,
        Market memory _market,
        uint256 _sellerAssets,
        uint256 _units,
        uint256 _pendingFeeDecrease,
        address _seller,
        address _receiver,
        bytes memory _data
    )
        external
        returns (bytes32)
    {
        _pendingFeeDecrease;
        MidnightModuleStorage storage $ = _getMidnightModuleStorage();
        address _midnightAddress = _midnight($);
        require(msg.sender == _midnightAddress, MIDNIGHT_ONLY_MIDNIGHT);
        require(_seller == address(this), MIDNIGHT_INVALID_SELLER);
        require(_receiver != address(0), MIDNIGHT_INVALID_RECEIVER);
        require(_market.loanToken != address(0), MIDNIGHT_INVALID_LOAN_TOKEN);
        require(_id == _marketToId(_midnightAddress, _market), MIDNIGHT_INVALID_MARKET);

        if (_data.length != 0) {
            SellCallbackData memory _callbackData = abi.decode(_data, (SellCallbackData));
            require(
                _callbackData.expectedMarketId == bytes32(0) || _callbackData.expectedMarketId == _id,
                MIDNIGHT_INVALID_MARKET
            );
            require(
                _callbackData.expectedReceiver == address(0) || _callbackData.expectedReceiver == _receiver,
                MIDNIGHT_INVALID_RECEIVER
            );
            require(
                _callbackData.minFinalLoanTokenBalance == 0
                    || IERC20(_market.loanToken).balanceOf(address(this)) >= _callbackData.minFinalLoanTokenBalance,
                MIDNIGHT_INSUFFICIENT_LIQUIDITY
            );
        }

        emit SellCallback(_id, _seller, _receiver, _sellerAssets, _units);
        return CALLBACK_SUCCESS;
    }

    function selectors() external pure returns (bytes4[] memory _selectors) {
        _selectors = new bytes4[](10);
        _selectors[0] = this.setMidnightConfig.selector;
        _selectors[1] = this.setIdleLiquidityCap.selector;
        _selectors[2] = this.idleLiquidityCap.selector;
        _selectors[3] = this.setWithdrawalQueue.selector;
        _selectors[4] = this.clearWithdrawalQueue.selector;
        _selectors[5] = this.withdrawalQueue.selector;
        _selectors[6] = this.withdrawalQueueLength.selector;
        _selectors[7] = this.loanTokenQueueId.selector;
        _selectors[8] = this.onBuy.selector;
        _selectors[9] = this.onSell.selector;
        return _selectors;
    }

    function _validateWithdrawalStep(address _loanToken, WithdrawalStep calldata _step) internal pure {
        if (_step.kind == WithdrawalStepKind.Disabled) {
            require(
                _step.target == address(0) && _step.value == 0 && _step.callData.length == 0
                    && _step.amountPlaceholderOffset == 0 && _step.maxWithdrawAssets == 0 && _step.minLoanTokenOut == 0
                    && _step.expectedOutputToken == address(0),
                MIDNIGHT_INVALID_LIQUIDATION_STEP
            );
        } else if (_step.kind == WithdrawalStepKind.Adapter) {
            require(
                _step.target != address(0) && _step.value == 0 && _step.callData.length == 0
                    && _step.amountPlaceholderOffset == 0 && _step.maxWithdrawAssets > 0
                    && _step.expectedOutputToken == _loanToken,
                MIDNIGHT_INVALID_LIQUIDATION_STEP
            );
        } else if (_step.kind == WithdrawalStepKind.RawCall) {
            require(
                _step.target != address(0) && _step.callData.length >= 4 && _step.maxWithdrawAssets > 0
                    && _step.expectedOutputToken == _loanToken,
                MIDNIGHT_INVALID_LIQUIDATION_STEP
            );
            _validatePlaceholderOffset(_step.callData.length, _step.amountPlaceholderOffset);
        } else {
            revert(MIDNIGHT_INVALID_LIQUIDATION_STEP);
        }
    }

    function _fundLoanToken(
        MidnightModuleStorage storage $,
        bytes32 _queueId,
        address _loanToken,
        uint256 _buyerAssets,
        uint256 _minFinalLoanTokenBalance
    )
        internal
    {
        uint256 _initialBalance = IERC20(_loanToken).balanceOf(address(this));
        uint256 _cap = $.idleLiquidityCaps[_loanToken];
        uint256 _protectedIdle = _initialBalance > _cap ? _initialBalance - _cap : 0;
        uint256 _requiredFinal = _protectedIdle > _minFinalLoanTokenBalance ? _protectedIdle : _minFinalLoanTokenBalance;
        uint256 _targetBalance = _buyerAssets + _requiredFinal;
        uint256 _balance = _initialBalance;

        if (_balance < _targetBalance) {
            _executeWithdrawalQueueUntilFunded($, _queueId, _loanToken, _targetBalance, _balance);
            _balance = IERC20(_loanToken).balanceOf(address(this));
        }

        require(_balance >= _targetBalance, MIDNIGHT_INSUFFICIENT_LIQUIDITY);

        uint256 _usableIdle = _initialBalance > _protectedIdle ? _initialBalance - _protectedIdle : 0;
        if (_usableIdle > _buyerAssets) _usableIdle = _buyerAssets;
        emit LoanTokenFunded(_loanToken, _buyerAssets, _usableIdle, _balance - _initialBalance);
    }

    function _executeWithdrawalQueueUntilFunded(
        MidnightModuleStorage storage $,
        bytes32 _queueId,
        address _loanToken,
        uint256 _targetBalance,
        uint256 _startingBalance
    )
        internal
    {
        WithdrawalQueue storage _queue = $.withdrawalQueues[_queueId];
        uint256 _length = _queue.steps.length;
        require(
            (_queue.loanToken == address(0) && _length == 0) || _queue.loanToken == _loanToken,
            MIDNIGHT_INVALID_LOAN_TOKEN
        );

        uint256 _balance = _startingBalance;

        for (uint256 _i; _i < _length && _balance < _targetBalance; ++_i) {
            WithdrawalStep storage _step = _queue.steps[_i];
            if (_step.kind == WithdrawalStepKind.Disabled) continue;

            uint256 _needed = _targetBalance - _balance;
            uint256 _amountIn = _needed < _step.maxWithdrawAssets ? _needed : _step.maxWithdrawAssets;

            uint256 _before = IERC20(_loanToken).balanceOf(address(this));

            if (_step.kind == WithdrawalStepKind.Adapter) {
                bytes memory _adapterCallData =
                    abi.encodeCall(IStrategyLiquidationAdapter.liquidate, (_amountIn, address(this)));
                _authorizeCall(_step.target, _adapterCallData);
                IStrategyLiquidationAdapter(_step.target).liquidate(_amountIn, address(this));
            } else {
                bytes memory _callData = _step.callData;
                _patchAmount(_callData, _step.amountPlaceholderOffset, _amountIn);

                _authorizeCall(_step.target, _callData);
                (bool _success,) = _step.target.call{ value: _step.value }(_callData);
                require(_success, MIDNIGHT_LIQUIDATION_CALL_FAILED);
            }

            uint256 _after = IERC20(_loanToken).balanceOf(address(this));
            uint256 _amountOut = _after - _before;
            require(_amountOut >= _step.minLoanTokenOut, MIDNIGHT_INSUFFICIENT_STEP_OUTPUT);

            _balance = _after;
            emit WithdrawalStepExecuted(_queueId, _loanToken, _i, _step.target, _amountIn, _amountOut);
        }
    }

    function _marketToId(address _midnightAddress, Market memory _market) internal view returns (bytes32 _id) {
        return IMidnight(_midnightAddress).toId(_market);
    }

    function _authorizeCall(address _target, bytes memory _callData) internal {
        bytes4 _selector;
        assembly ("memory-safe") {
            _selector := mload(add(_callData, 32))
        }
        _getMinimalAccountStorage().registry.authorizeCall(_target, _selector, _sliceParams(_callData));
    }

    function _sliceParams(bytes memory _callData) internal pure returns (bytes memory _params) {
        if (_callData.length <= 4) return new bytes(0);
        uint256 _length = _callData.length - 4;
        _params = new bytes(_length);
        for (uint256 _i; _i < _length; ++_i) {
            _params[_i] = _callData[_i + 4];
        }
    }

    function _patchAmount(bytes memory _callData, uint256 _amountPlaceholderOffset, uint256 _amount) internal pure {
        _validatePlaceholderOffset(_callData.length, _amountPlaceholderOffset);
        assembly ("memory-safe") {
            mstore(add(add(_callData, 32), _amountPlaceholderOffset), _amount)
        }
    }

    function _validatePlaceholderOffset(uint256 _callDataLength, uint256 _amountPlaceholderOffset) internal pure {
        require(
            _callDataLength >= 36 && _amountPlaceholderOffset >= 4 && _amountPlaceholderOffset <= _callDataLength - 32,
            MIDNIGHT_INVALID_PLACEHOLDER_OFFSET
        );
    }
}
