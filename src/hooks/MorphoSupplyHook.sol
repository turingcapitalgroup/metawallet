// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

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
    HOOKMORPHOSUPPLY_INSUFFICIENT_SHARES,
    HOOKMORPHOSUPPLY_INVALID_HOOK_DATA,
    HOOKMORPHOSUPPLY_PREVIOUS_HOOK_NOT_FOUND
} from "metawallet/src/errors/Errors.sol";

/// @title MorphoSupplyHook
/// @notice Hook for supplying assets into Morpho Blue markets
/// @dev This hook performs two operations:
///      1. Approves the Morpho Blue singleton to spend the loan token
///      2. Supplies the assets into a specific Morpho Blue market
///      This is an INFLOW hook as it increases the supply position
///      Stores execution context that can be read by subsequent hooks in the chain
///      Supports dynamic amounts by reading from previous hook's output
contract MorphoSupplyHook is IHook, IHookResult, Ownable {
    using SafeTransferLib for address;
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
    /// @param assetsSupplied The amount of assets supplied
    /// @param sharesReceived The amount of supply shares received
    /// @param onBehalf The address that was credited with the supply position
    /// @param timestamp The timestamp of the supply
    struct SupplyContext {
        address morpho;
        address loanToken;
        uint256 assetsSupplied;
        uint256 sharesReceived;
        address onBehalf;
        uint256 timestamp;
    }

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Tracks whether the hook is currently executing
    bool private _executionContext;

    /// @notice Stores supply context data for the current execution
    /// @dev This allows subsequent hooks to access supply details
    SupplyContext private _supplyContext;

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for Morpho Blue supply operation
    /// @param morpho The Morpho Blue singleton address
    /// @param marketParams The market parameters identifying the target market
    /// @param assets The amount of loan token to supply (use USE_PREVIOUS_HOOK_OUTPUT for dynamic)
    /// @param onBehalf The address that will own the supply position
    /// @param minShares Minimum supply shares expected (slippage protection)
    struct SupplyData {
        address morpho;
        MarketParams marketParams;
        uint256 assets;
        address onBehalf;
        uint256 minShares;
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
        SupplyData memory _supplyData = abi.decode(_data, (SupplyData));

        require(_supplyData.morpho != address(0), HOOKMORPHOSUPPLY_INVALID_HOOK_DATA);
        require(_supplyData.onBehalf != address(0), HOOKMORPHOSUPPLY_INVALID_HOOK_DATA);
        require(_supplyData.marketParams.loanToken != address(0), HOOKMORPHOSUPPLY_INVALID_HOOK_DATA);

        bool _useDynamicAmount = _supplyData.assets == USE_PREVIOUS_HOOK_OUTPUT;

        if (_useDynamicAmount) {
            require(_previousHook != address(0), HOOKMORPHOSUPPLY_PREVIOUS_HOOK_NOT_FOUND);

            // [resolveDynamicAmount, approveForSupply, executeSupply, (optional) validateMinShares]
            uint256 _execCount = _supplyData.minShares > 0 ? 4 : 3;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.resolveDynamicAmount.selector, _previousHook, _supplyData.morpho, _supplyData.marketParams
                )
            });

            _executions[1] = Execution({
                target: address(this), value: 0, callData: abi.encodeWithSelector(this.approveForSupply.selector)
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.executeSupply.selector, _supplyData.onBehalf, _supplyData.marketParams
                )
            });

            if (_supplyData.minShares > 0) {
                _executions[3] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinShares.selector, _supplyData.minShares)
                });
            }
        } else {
            require(_supplyData.assets > 0, HOOKMORPHOSUPPLY_INVALID_HOOK_DATA);

            // [transfer, approve, supply, storeContext, (optional) validateMinShares]
            uint256 _execCount = _supplyData.minShares > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: _supplyData.marketParams.loanToken,
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(this), _supplyData.assets)
            });

            _executions[1] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.approveForSupplyStatic.selector,
                    _supplyData.marketParams.loanToken,
                    _supplyData.morpho,
                    _supplyData.assets
                )
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.executeSupplyStatic.selector,
                    _supplyData.morpho,
                    _supplyData.marketParams,
                    _supplyData.assets,
                    _supplyData.onBehalf
                )
            });

            _executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.storeSupplyContextStatic.selector,
                    _supplyData.morpho,
                    _supplyData.marketParams.loanToken,
                    _supplyData.assets,
                    _supplyData.onBehalf
                )
            });

            if (_supplyData.minShares > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinShares.selector, _supplyData.minShares)
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

        delete _supplyContext;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
    function getOutputAmount() external view override returns (uint256 _outputAmount) {
        return _supplyContext.sharesReceived;
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT RESOLUTION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Resolve the dynamic amount from the previous hook
    /// @dev Called during execution to get amount from previous hook's output
    /// @param _previousHook The address of the previous hook
    /// @param _morpho The Morpho Blue singleton address (stored for later use)
    /// @param _marketParams The market parameters (loanToken extracted for later use)
    function resolveDynamicAmount(
        address _previousHook,
        address _morpho,
        MarketParams memory _marketParams
    )
        external
        onlyOwner
    {
        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOKMORPHOSUPPLY_INVALID_HOOK_DATA);

        _supplyContext = SupplyContext({
            morpho: _morpho,
            loanToken: _marketParams.loanToken,
            assetsSupplied: _amount,
            sharesReceived: 0, // Will be updated after supply
            onBehalf: address(0), // Will be updated after supply
            timestamp: block.timestamp
        });
    }

    /// @notice Approve Morpho to spend loan tokens (for dynamic amount flow)
    /// @dev Uses stored context to determine morpho address and amount
    function approveForSupply() external onlyOwner {
        SupplyContext memory _ctx = _supplyContext;
        _ctx.loanToken.safeApproveWithRetry(_ctx.morpho, _ctx.assetsSupplied);
    }

    /// @notice Approve Morpho to spend loan tokens (for static amount flow)
    /// @param _loanToken The loan token address to approve
    /// @param _morpho The Morpho Blue singleton address (spender)
    /// @param _amount The amount to approve
    function approveForSupplyStatic(address _loanToken, address _morpho, uint256 _amount) external onlyOwner {
        _loanToken.safeApproveWithRetry(_morpho, _amount);
    }

    /// @notice Execute the supply (for dynamic amount flow)
    /// @dev Uses position delta to measure supply shares received
    /// @param _onBehalf The address to credit with the supply position
    /// @param _marketParams The market parameters
    function executeSupply(address _onBehalf, MarketParams memory _marketParams) external onlyOwner {
        SupplyContext storage _ctx = _supplyContext;
        Id _marketId = _marketParams.id();
        (uint256 _sharesBefore,,) = IMorpho(_ctx.morpho).position(_marketId, _onBehalf);
        IMorpho(_ctx.morpho).supply(_marketParams, _ctx.assetsSupplied, 0, _onBehalf, "");
        (uint256 _sharesAfter,,) = IMorpho(_ctx.morpho).position(_marketId, _onBehalf);
        _ctx.onBehalf = _onBehalf;
        _ctx.sharesReceived = _sharesAfter - _sharesBefore;

        // Reset approval after supply
        _ctx.loanToken.safeApprove(_ctx.morpho, 0);
    }

    /// @notice Execute the supply (for static amount flow)
    /// @dev Uses position delta to measure supply shares received
    /// @param _morpho The Morpho Blue singleton address
    /// @param _marketParams The market parameters
    /// @param _assets The amount of assets to supply
    /// @param _onBehalf The address to credit with the supply position
    function executeSupplyStatic(
        address _morpho,
        MarketParams memory _marketParams,
        uint256 _assets,
        address _onBehalf
    )
        external
        onlyOwner
    {
        Id _marketId = _marketParams.id();
        (uint256 _sharesBefore,,) = IMorpho(_morpho).position(_marketId, _onBehalf);
        IMorpho(_morpho).supply(_marketParams, _assets, 0, _onBehalf, "");
        (uint256 _sharesAfter,,) = IMorpho(_morpho).position(_marketId, _onBehalf);
        _supplyContext.sharesReceived = _sharesAfter - _sharesBefore;

        // Reset approval after supply
        _marketParams.loanToken.safeApprove(_morpho, 0);
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store supply context after execution (for static amount flow)
    /// @dev Called as part of the execution chain to save context for next hook
    /// @dev sharesReceived is already set in executeSupplyStatic from the position delta
    /// @param _morpho The Morpho Blue singleton address
    /// @param _loanToken The loan token address
    /// @param _assetsSupplied The amount of assets supplied
    /// @param _onBehalf The address credited with the supply position
    function storeSupplyContextStatic(
        address _morpho,
        address _loanToken,
        uint256 _assetsSupplied,
        address _onBehalf
    )
        external
        onlyOwner
    {
        uint256 _sharesReceived = _supplyContext.sharesReceived;

        _supplyContext = SupplyContext({
            morpho: _morpho,
            loanToken: _loanToken,
            assetsSupplied: _assetsSupplied,
            sharesReceived: _sharesReceived,
            onBehalf: _onBehalf,
            timestamp: block.timestamp
        });
    }

    /* ///////////////////////////////////////////////////////////////
                         VALIDATION HELPERS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Validates that the supply produced at least the minimum expected shares
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param _minShares The minimum expected supply shares
    function validateMinShares(uint256 _minShares) external view onlyOwner {
        require(_supplyContext.sharesReceived >= _minShares, HOOKMORPHOSUPPLY_INSUFFICIENT_SHARES);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if the hook has an active execution context
    /// @return _hasContext Whether there is an active execution context
    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    /// @notice Get the stored supply context
    /// @return _context The stored supply context
    function getSupplyContext() external view returns (SupplyContext memory _context) {
        return _supplyContext;
    }

    /// @notice Get the Morpho address from the last supply
    /// @return _morpho The Morpho Blue singleton address
    function getLastMorpho() external view returns (address _morpho) {
        return _supplyContext.morpho;
    }

    /// @notice Get the supply shares received from the last supply
    /// @return _shares The amount of supply shares received
    function getLastSharesReceived() external view returns (uint256 _shares) {
        return _supplyContext.sharesReceived;
    }

    /// @notice Get the assets supplied in the last operation
    /// @return _assets The amount of assets supplied
    function getLastAssetsSupplied() external view returns (uint256 _assets) {
        return _supplyContext.assetsSupplied;
    }

    /// @notice Preview the supply shares that would be received for a given asset amount
    /// @param _morpho The Morpho Blue singleton address
    /// @param _marketParams The market parameters
    /// @param _assets The amount of assets to supply
    /// @return _shares The estimated supply shares (rounded down)
    function previewSupplyShares(
        address _morpho,
        MarketParams memory _marketParams,
        uint256 _assets
    )
        external
        view
        returns (uint256 _shares)
    {
        Id _marketId = _marketParams.id();
        Market memory _market = IMorpho(_morpho).market(_marketId);
        return _assets.toSharesDown(_market.totalSupplyAssets, _market.totalSupplyShares);
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
