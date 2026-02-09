// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "solady/auth/Ownable.sol";

// Local Interfaces
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { IHookResult } from "metawallet/src/interfaces/IHookResult.sol";

// External Libraries
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

// Morpho Blue
import { IMorpho, Id, Market, MarketParams } from "morpho-blue/interfaces/IMorpho.sol";
import { MarketParamsLib } from "morpho-blue/libraries/MarketParamsLib.sol";
import { SharesMathLib } from "morpho-blue/libraries/SharesMathLib.sol";

// Local Errors
import {
    HOOKMORPHOWITHDRAW_INSUFFICIENT_ASSETS,
    HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA,
    HOOKMORPHOWITHDRAW_PREVIOUS_HOOK_NOT_FOUND
} from "metawallet/src/errors/Errors.sol";

/// @title MorphoWithdrawHook
/// @notice Hook for withdrawing assets from Morpho Blue markets
/// @dev This hook performs the withdraw operation which burns supply shares to receive underlying assets
///      This is an OUTFLOW hook as it decreases the supply position
///      Stores execution context that can be read by subsequent hooks in the chain
///      Supports dynamic amounts by reading from previous hook's output
contract MorphoWithdrawHook is IHook, IHookResult, Ownable {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Special value indicating amount should be read from previous hook
    uint256 public constant USE_PREVIOUS_HOOK_OUTPUT = type(uint256).max;

    /* ///////////////////////////////////////////////////////////////
                              STRUCTURES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Context data stored during execution for hook chaining
    /// @param morpho The Morpho Blue singleton address
    /// @param loanToken The loan token address
    /// @param assetsRequested The amount of assets requested to withdraw
    /// @param assetsReceived The actual amount of assets received (measured via balance delta)
    /// @param onBehalf The owner of the supply position
    /// @param receiver The address that received the withdrawn assets
    /// @param timestamp The timestamp of the withdrawal
    struct WithdrawContext {
        address morpho;
        address loanToken;
        uint256 assetsRequested;
        uint256 assetsReceived;
        address onBehalf;
        address receiver;
        uint256 timestamp;
    }

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Tracks whether the hook is currently executing
    bool private _executionContext;

    /// @notice Stores withdraw context data for the current execution
    /// @dev This allows subsequent hooks to access withdrawal details
    WithdrawContext private _withdrawContext;

    /// @notice Pre-action balance snapshot for delta computation (used in static flow)
    uint256 private _preActionBalance;

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for Morpho Blue withdraw operation
    /// @param morpho The Morpho Blue singleton address
    /// @param marketParams The market parameters identifying the target market
    /// @param assets The amount of assets to withdraw (use USE_PREVIOUS_HOOK_OUTPUT for dynamic)
    /// @param shares The amount of shares to burn (exactly one of assets/shares must be non-zero in static flow)
    /// @param onBehalf The owner of the supply position to withdraw from
    /// @param receiver The address that will receive the withdrawn assets
    /// @param minAssets Minimum assets expected (slippage protection)
    struct WithdrawData {
        address morpho;
        MarketParams marketParams;
        uint256 assets;
        uint256 shares;
        address onBehalf;
        address receiver;
        uint256 minAssets;
    }

    /// @notice Deploys the hook and sets the initial owner
    /// @param _owner The address that will own this hook
    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOK IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHook
    function buildExecutions(
        address _previousHook,
        bytes calldata _data
    )
        external
        view
        override
        onlyOwner
        returns (Execution[] memory _executions)
    {
        WithdrawData memory _withdrawData = abi.decode(_data, (WithdrawData));

        require(_withdrawData.morpho != address(0), HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA);
        require(_withdrawData.onBehalf != address(0), HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA);
        require(_withdrawData.receiver != address(0), HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA);
        require(_withdrawData.marketParams.loanToken != address(0), HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA);

        bool _useDynamicAmount = _withdrawData.assets == USE_PREVIOUS_HOOK_OUTPUT;

        if (_useDynamicAmount) {
            require(_previousHook != address(0), HOOKMORPHOWITHDRAW_PREVIOUS_HOOK_NOT_FOUND);

            // [resolveDynamicAmount, setAuthorization(true), executeWithdraw, setAuthorization(false), (optional) validate]
            uint256 _execCount = _withdrawData.minAssets > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.resolveDynamicAmount.selector,
                    _previousHook,
                    _withdrawData.morpho,
                    _withdrawData.marketParams,
                    _withdrawData.onBehalf
                )
            });

            // Wallet authorizes hook in Morpho so hook can withdraw on wallet's behalf
            _executions[1] = Execution({
                target: _withdrawData.morpho,
                value: 0,
                callData: abi.encodeWithSelector(IMorpho.setAuthorization.selector, address(this), true)
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.executeWithdraw.selector, _withdrawData.receiver, _withdrawData.marketParams
                )
            });

            // Revoke authorization after use
            _executions[3] = Execution({
                target: _withdrawData.morpho,
                value: 0,
                callData: abi.encodeWithSelector(IMorpho.setAuthorization.selector, address(this), false)
            });

            if (_withdrawData.minAssets > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinAssets.selector, _withdrawData.minAssets)
                });
            }
        } else {
            require(_withdrawData.assets > 0 || _withdrawData.shares > 0, HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA);

            // [snapshot, withdraw (wallet calls Morpho directly), storeContext, (optional) validate]
            uint256 _execCount = _withdrawData.minAssets > 0 ? 4 : 3;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.snapshotBalance.selector, _withdrawData.marketParams.loanToken, _withdrawData.receiver
                )
            });

            // Wallet calls morpho.withdraw directly (wallet is msg.sender and onBehalf)
            // Morpho validates exactly one of assets/shares is non-zero
            _executions[1] = Execution({
                target: _withdrawData.morpho,
                value: 0,
                callData: abi.encodeWithSelector(
                    IMorpho.withdraw.selector,
                    _withdrawData.marketParams,
                    _withdrawData.assets,
                    _withdrawData.shares,
                    _withdrawData.onBehalf,
                    _withdrawData.receiver
                )
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.storeWithdrawContextStatic.selector,
                    _withdrawData.morpho,
                    _withdrawData.marketParams.loanToken,
                    _withdrawData.assets,
                    _withdrawData.receiver,
                    _withdrawData.onBehalf
                )
            });

            if (_withdrawData.minAssets > 0) {
                _executions[3] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinAssets.selector, _withdrawData.minAssets)
                });
            }
        }
    }

    /// @inheritdoc IHook
    function initializeHookContext() external override onlyOwner {
        _executionContext = true;
    }

    /// @inheritdoc IHook
    function finalizeHookContext() external override onlyOwner {
        _executionContext = false;

        delete _withdrawContext;
        delete _preActionBalance;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
    function getOutputAmount() external view override returns (uint256 _outputAmount) {
        return _withdrawContext.assetsReceived;
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT RESOLUTION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Resolve the dynamic amount from the previous hook
    /// @dev Called during execution to get amount from previous hook's output
    /// @param _previousHook The address of the previous hook
    /// @param _morpho The Morpho Blue singleton address (stored for later use)
    /// @param _marketParams The market parameters (loanToken extracted for later use)
    /// @param _onBehalf The owner of the supply position (stored for later use)
    function resolveDynamicAmount(
        address _previousHook,
        address _morpho,
        MarketParams memory _marketParams,
        address _onBehalf
    )
        external
        onlyOwner
    {
        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA);

        _withdrawContext = WithdrawContext({
            morpho: _morpho,
            loanToken: _marketParams.loanToken,
            assetsRequested: _amount,
            assetsReceived: 0,
            onBehalf: _onBehalf,
            receiver: address(0),
            timestamp: block.timestamp
        });
    }

    /// @notice Snapshot the receiver's loan token balance before a static withdraw
    /// @dev Called before the morpho.withdraw() execution to enable delta computation
    /// @param _token The loan token to snapshot
    /// @param _account The account whose balance to snapshot
    function snapshotBalance(address _token, address _account) external onlyOwner {
        _preActionBalance = IERC20(_token).balanceOf(_account);
    }

    /// @notice Execute the withdrawal (for dynamic amount flow)
    /// @dev Uses balance delta to measure assets received instead of trusting return value
    /// @param _receiver The address to receive the withdrawn assets
    /// @param _marketParams The market parameters
    function executeWithdraw(address _receiver, MarketParams memory _marketParams) external onlyOwner {
        WithdrawContext storage _ctx = _withdrawContext;
        uint256 _balanceBefore = IERC20(_ctx.loanToken).balanceOf(_receiver);
        IMorpho(_ctx.morpho).withdraw(_marketParams, _ctx.assetsRequested, 0, _ctx.onBehalf, _receiver);
        uint256 _assetsReceived = IERC20(_ctx.loanToken).balanceOf(_receiver) - _balanceBefore;
        _ctx.receiver = _receiver;
        _ctx.assetsReceived = _assetsReceived;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store withdraw context after execution (for static amount flow)
    /// @dev Called as part of the execution chain to save context for next hook
    /// @dev Uses balance delta (current - snapshot) to correctly measure assets received
    /// @param _morpho The Morpho Blue singleton address
    /// @param _loanToken The loan token address
    /// @param _assetsRequested The amount of assets requested to withdraw
    /// @param _receiver The address that received the assets
    /// @param _onBehalf The owner of the supply position
    function storeWithdrawContextStatic(
        address _morpho,
        address _loanToken,
        uint256 _assetsRequested,
        address _receiver,
        address _onBehalf
    )
        external
        onlyOwner
    {
        uint256 _assetsReceived = IERC20(_loanToken).balanceOf(_receiver) - _preActionBalance;

        _withdrawContext = WithdrawContext({
            morpho: _morpho,
            loanToken: _loanToken,
            assetsRequested: _assetsRequested,
            assetsReceived: _assetsReceived,
            onBehalf: _onBehalf,
            receiver: _receiver,
            timestamp: block.timestamp
        });
    }

    /* ///////////////////////////////////////////////////////////////
                         VALIDATION HELPERS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Validates that the withdrawal produced at least the minimum expected assets
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param _minAssets The minimum expected assets
    function validateMinAssets(uint256 _minAssets) external view onlyOwner {
        require(_withdrawContext.assetsReceived >= _minAssets, HOOKMORPHOWITHDRAW_INSUFFICIENT_ASSETS);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if the hook has an active execution context
    /// @return _hasContext Whether there is an active execution context
    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    /// @notice Get the stored withdraw context
    /// @return _context The stored withdraw context
    function getWithdrawContext() external view returns (WithdrawContext memory _context) {
        return _withdrawContext;
    }

    /// @notice Get the Morpho address from the last withdrawal
    /// @return _morpho The Morpho Blue singleton address
    function getLastMorpho() external view returns (address _morpho) {
        return _withdrawContext.morpho;
    }

    /// @notice Get the assets received from the last withdrawal
    /// @return _assets The amount of assets received
    function getLastAssetsReceived() external view returns (uint256 _assets) {
        return _withdrawContext.assetsReceived;
    }

    /// @notice Get the assets requested in the last operation
    /// @return _assets The amount of assets requested
    function getLastAssetsRequested() external view returns (uint256 _assets) {
        return _withdrawContext.assetsRequested;
    }

    /// @notice Get the loan token from the last withdrawal
    /// @return _loanToken The loan token address
    function getLastLoanToken() external view returns (address _loanToken) {
        return _withdrawContext.loanToken;
    }

    /// @notice Preview the assets receivable for a given share amount
    /// @param _morpho The Morpho Blue singleton address
    /// @param _marketParams The market parameters
    /// @param _shares The amount of shares to convert
    /// @return _assets The estimated assets receivable (rounded down)
    function previewWithdrawAssets(
        address _morpho,
        MarketParams memory _marketParams,
        uint256 _shares
    )
        external
        view
        returns (uint256 _assets)
    {
        Id _marketId = _marketParams.id();
        Market memory _market = IMorpho(_morpho).market(_marketId);
        return _shares.toAssetsDown(_market.totalSupplyAssets, _market.totalSupplyShares);
    }

    /// @notice Get the current supply position (shares) for an account in a market
    /// @param _morpho The Morpho Blue singleton address
    /// @param _marketParams The market parameters
    /// @param _account The account to query
    /// @return _supplyShares The account's supply shares
    function getSupplyPosition(
        address _morpho,
        MarketParams memory _marketParams,
        address _account
    )
        external
        view
        returns (uint256 _supplyShares)
    {
        Id _marketId = _marketParams.id();
        (_supplyShares,,) = IMorpho(_morpho).position(_marketId, _account);
    }
}
