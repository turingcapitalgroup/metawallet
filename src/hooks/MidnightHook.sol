// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "solady/auth/Ownable.sol";

import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { IHookResult } from "metawallet/src/interfaces/IHookResult.sol";
import { IMidnight, Market, Offer } from "metawallet/src/interfaces/IMidnight.sol";
import { ISetterRatifier } from "metawallet/src/interfaces/ISetterRatifier.sol";
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

import {
    HOOKMIDNIGHT_INACTIVE_CONTEXT,
    HOOKMIDNIGHT_INSUFFICIENT_OUTPUT,
    HOOKMIDNIGHT_INVALID_HOOK_DATA
} from "metawallet/src/errors/Errors.sol";

/// @title MidnightHook
/// @notice Builds MetaWallet executions for non-callback Midnight protocol actions.
contract MidnightHook is IHook, IHookResult, Ownable {
    enum Action {
        WithdrawCredits,
        TakeOffer,
        SetAuthorization,
        RatifyOfferTree,
        CancelOfferGroup
    }

    struct HookData {
        Action action;
        bytes actionData;
        uint256 minAmountOut;
    }

    struct WithdrawCreditsData {
        address midnight;
        Market market;
        uint256 units;
        address receiver;
    }

    struct TakeOfferData {
        address midnight;
        Offer offer;
        bytes ratifierData;
        uint256 units;
        address receiverIfTakerIsSeller;
        address takerCallback;
        bytes takerCallbackData;
    }

    struct SetAuthorizationData {
        address midnight;
        address authorized;
        bool enabled;
    }

    struct RatifyOfferTreeData {
        address setterRatifier;
        bytes32 root;
        bool enabled;
    }

    struct CancelOfferGroupData {
        address midnight;
        bytes32 group;
        uint256 amount;
    }

    struct ActionContext {
        Action action;
        address target;
        address loanToken;
        address receiver;
        uint256 units;
        uint256 amountOut;
        uint256 timestamp;
    }

    event MidnightAuthorizationUpdated(
        address indexed midnight, address indexed maker, address indexed authorized, bool enabled
    );
    event OfferTreeRatified(address indexed setterRatifier, address indexed maker, bytes32 indexed root, bool enabled);
    event OfferGroupCancelled(address indexed midnight, address indexed maker, bytes32 indexed group, uint256 amount);
    event CreditsWithdrawn(address indexed midnight, bytes32 indexed marketId, address indexed receiver, uint256 units);
    event OfferTaken(
        address indexed midnight,
        bytes32 indexed marketId,
        address indexed maker,
        address taker,
        uint256 units,
        uint256 amountOut
    );

    bool private _executionContext;
    uint256 private _preActionBalance;
    ActionContext private _actionContext;

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    function buildExecutions(address, bytes calldata _data) external view returns (Execution[] memory _executions) {
        HookData memory _hookData = abi.decode(_data, (HookData));

        if (_hookData.action == Action.WithdrawCredits) {
            return _buildWithdrawCreditsExecutions(_hookData.actionData, _hookData.minAmountOut);
        }
        if (_hookData.action == Action.TakeOffer) {
            return _buildTakeOfferExecutions(_hookData.actionData, _hookData.minAmountOut);
        }
        if (_hookData.action == Action.SetAuthorization) {
            return _buildSetAuthorizationExecutions(_hookData.actionData);
        }
        if (_hookData.action == Action.RatifyOfferTree) {
            return _buildRatifyOfferTreeExecutions(_hookData.actionData);
        }
        if (_hookData.action == Action.CancelOfferGroup) {
            return _buildCancelOfferGroupExecutions(_hookData.actionData);
        }

        revert(HOOKMIDNIGHT_INVALID_HOOK_DATA);
    }

    function initializeHookContext() external onlyOwner {
        _executionContext = true;
    }

    function finalizeHookContext() external onlyOwner {
        _executionContext = false;
        delete _preActionBalance;
        delete _actionContext;
    }

    function getOutputAmount() external view returns (uint256 _outputAmount) {
        return _actionContext.amountOut;
    }

    function snapshotBalance(address _token, address _account) external onlyOwner {
        require(_executionContext, HOOKMIDNIGHT_INACTIVE_CONTEXT);
        _preActionBalance = IERC20(_token).balanceOf(_account);
    }

    function storeWithdrawCreditsContext(
        address _midnight,
        Market calldata _market,
        uint256 _units,
        address _receiver
    )
        external
        onlyOwner
    {
        require(_executionContext, HOOKMIDNIGHT_INACTIVE_CONTEXT);
        uint256 _amountOut = IERC20(_market.loanToken).balanceOf(_receiver) - _preActionBalance;
        _actionContext = ActionContext({
            action: Action.WithdrawCredits,
            target: _midnight,
            loanToken: _market.loanToken,
            receiver: _receiver,
            units: _units,
            amountOut: _amountOut,
            timestamp: block.timestamp
        });
        emit CreditsWithdrawn(_midnight, IMidnight(_midnight).toId(_market), _receiver, _units);
    }

    function storeTakeOfferContext(
        address _midnight,
        Offer calldata _offer,
        uint256 _units,
        address _receiver
    )
        external
        onlyOwner
    {
        require(_executionContext, HOOKMIDNIGHT_INACTIVE_CONTEXT);
        uint256 _amountOut = IERC20(_offer.market.loanToken).balanceOf(_receiver) - _preActionBalance;
        _actionContext = ActionContext({
            action: Action.TakeOffer,
            target: _midnight,
            loanToken: _offer.market.loanToken,
            receiver: _receiver,
            units: _units,
            amountOut: _amountOut,
            timestamp: block.timestamp
        });
        emit OfferTaken(_midnight, IMidnight(_midnight).toId(_offer.market), _offer.maker, owner(), _units, _amountOut);
    }

    function validateMinAmountOut(uint256 _minAmountOut) external view {
        require(_executionContext, HOOKMIDNIGHT_INACTIVE_CONTEXT);
        require(_actionContext.amountOut >= _minAmountOut, HOOKMIDNIGHT_INSUFFICIENT_OUTPUT);
    }

    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    function getActionContext() external view returns (ActionContext memory _context) {
        return _actionContext;
    }

    function _buildWithdrawCreditsExecutions(
        bytes memory _actionData,
        uint256 _minAmountOut
    )
        internal
        view
        returns (Execution[] memory _executions)
    {
        WithdrawCreditsData memory _withdrawData = abi.decode(_actionData, (WithdrawCreditsData));
        require(_withdrawData.midnight != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);
        require(_withdrawData.market.loanToken != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);
        require(_withdrawData.receiver != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);
        require(_withdrawData.units > 0, HOOKMIDNIGHT_INVALID_HOOK_DATA);

        uint256 _execCount = _minAmountOut > 0 ? 4 : 3;
        _executions = new Execution[](_execCount);
        _executions[0] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(
                this.snapshotBalance.selector, _withdrawData.market.loanToken, _withdrawData.receiver
            )
        });
        _executions[1] = Execution({
            target: _withdrawData.midnight,
            value: 0,
            callData: abi.encodeWithSelector(
                IMidnight.withdraw.selector, _withdrawData.market, _withdrawData.units, owner(), _withdrawData.receiver
            )
        });
        _executions[2] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(
                this.storeWithdrawCreditsContext.selector,
                _withdrawData.midnight,
                _withdrawData.market,
                _withdrawData.units,
                _withdrawData.receiver
            )
        });
        if (_minAmountOut > 0) {
            _executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.validateMinAmountOut.selector, _minAmountOut)
            });
        }
    }

    function _buildTakeOfferExecutions(
        bytes memory _actionData,
        uint256 _minAmountOut
    )
        internal
        view
        returns (Execution[] memory _executions)
    {
        TakeOfferData memory _takeData = abi.decode(_actionData, (TakeOfferData));
        require(_takeData.midnight != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);
        require(_takeData.offer.market.loanToken != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);
        require(_takeData.units > 0, HOOKMIDNIGHT_INVALID_HOOK_DATA);
        address _receiver =
            _takeData.offer.buy ? _takeData.receiverIfTakerIsSeller : _takeData.offer.receiverIfMakerIsSeller;
        require(_receiver != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);

        uint256 _execCount = _minAmountOut > 0 ? 4 : 3;
        _executions = new Execution[](_execCount);
        _executions[0] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(this.snapshotBalance.selector, _takeData.offer.market.loanToken, _receiver)
        });
        _executions[1] = Execution({
            target: _takeData.midnight,
            value: 0,
            callData: abi.encodeWithSelector(
                IMidnight.take.selector,
                _takeData.offer,
                _takeData.ratifierData,
                _takeData.units,
                owner(),
                _takeData.receiverIfTakerIsSeller,
                _takeData.takerCallback,
                _takeData.takerCallbackData
            )
        });
        _executions[2] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(
                this.storeTakeOfferContext.selector, _takeData.midnight, _takeData.offer, _takeData.units, _receiver
            )
        });
        if (_minAmountOut > 0) {
            _executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.validateMinAmountOut.selector, _minAmountOut)
            });
        }
    }

    function _buildSetAuthorizationExecutions(bytes memory _actionData)
        internal
        view
        returns (Execution[] memory _executions)
    {
        SetAuthorizationData memory _authorizationData = abi.decode(_actionData, (SetAuthorizationData));
        require(_authorizationData.midnight != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);
        require(_authorizationData.authorized != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);

        _executions = new Execution[](1);
        _executions[0] = Execution({
            target: _authorizationData.midnight,
            value: 0,
            callData: abi.encodeWithSelector(
                IMidnight.setIsAuthorized.selector, _authorizationData.authorized, _authorizationData.enabled, owner()
            )
        });
    }

    function _buildRatifyOfferTreeExecutions(bytes memory _actionData)
        internal
        view
        returns (Execution[] memory _executions)
    {
        RatifyOfferTreeData memory _ratifyData = abi.decode(_actionData, (RatifyOfferTreeData));
        require(_ratifyData.setterRatifier != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);

        _executions = new Execution[](1);
        _executions[0] = Execution({
            target: _ratifyData.setterRatifier,
            value: 0,
            callData: abi.encodeWithSelector(
                ISetterRatifier.setIsRootRatified.selector, owner(), _ratifyData.root, _ratifyData.enabled
            )
        });
    }

    function _buildCancelOfferGroupExecutions(bytes memory _actionData)
        internal
        view
        returns (Execution[] memory _executions)
    {
        CancelOfferGroupData memory _cancelData = abi.decode(_actionData, (CancelOfferGroupData));
        require(_cancelData.midnight != address(0), HOOKMIDNIGHT_INVALID_HOOK_DATA);

        _executions = new Execution[](1);
        _executions[0] = Execution({
            target: _cancelData.midnight,
            value: 0,
            callData: abi.encodeWithSelector(
                IMidnight.setConsumed.selector, _cancelData.group, _cancelData.amount, owner()
            )
        });
    }
}
