// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "solady/auth/Ownable.sol";

// Local Interfaces
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { IHookResult } from "metawallet/src/interfaces/IHookResult.sol";

// External Libraries
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

// Local Errors
import {
    HOOK4626REDEEM_INSUFFICIENT_ASSETS,
    HOOK4626REDEEM_INVALID_HOOK_DATA,
    HOOK4626REDEEM_PREVIOUS_HOOK_NO_OUTPUT
} from "metawallet/src/errors/Errors.sol";

/// @title ERC4626RedeemHook
/// @notice Hook for redeeming shares from ERC4626 vaults
/// @dev This hook performs the redeem operation which burns shares to receive underlying assets
///      This is an OUTFLOW hook as it decreases the vault share balance
///      Stores execution context that can be read by subsequent hooks in the chain
///      Supports dynamic amounts by reading from previous hook's output
contract ERC4626RedeemHook is IHook, IHookResult, Ownable {
    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Special value indicating amount should be read from previous hook
    uint256 public constant USE_PREVIOUS_HOOK_OUTPUT = type(uint256).max;

    /* ///////////////////////////////////////////////////////////////
                              STRUCTURES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Context data stored during execution for hook chaining
    /// @param vault The vault address that was redeemed from
    /// @param asset The underlying asset address
    /// @param sharesRedeemed The amount of shares redeemed
    /// @param assetsReceived The amount of assets received from redemption
    /// @param receiver The address that received the assets
    /// @param owner The owner of the redeemed shares
    /// @param timestamp The timestamp of the redemption
    struct RedeemContext {
        address vault;
        address asset;
        uint256 sharesRedeemed;
        uint256 assetsReceived;
        address receiver;
        address owner;
        uint256 timestamp;
    }

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Tracks whether the hook is currently executing
    bool private _executionContext;

    /// @notice Stores redeem context data for the current execution
    /// @dev This allows subsequent hooks to access redemption details
    RedeemContext private _redeemContext;

    /// @notice Pre-action balance snapshot for delta computation (used in static flow)
    uint256 private _preActionBalance;

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for redeem operation
    /// @param vault The ERC4626 vault address
    /// @param shares The amount of shares to redeem (use USE_PREVIOUS_HOOK_OUTPUT for dynamic)
    /// @param receiver The address that will receive the underlying assets
    /// @param owner The owner of the shares being redeemed
    /// @param minAssets Minimum assets expected (slippage protection)
    struct RedeemData {
        address vault;
        uint256 shares;
        address receiver;
        address owner;
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
        RedeemData memory _redeemData = abi.decode(_data, (RedeemData));

        require(_redeemData.vault != address(0), HOOK4626REDEEM_INVALID_HOOK_DATA);
        require(_redeemData.receiver != address(0), HOOK4626REDEEM_INVALID_HOOK_DATA);
        require(_redeemData.owner != address(0), HOOK4626REDEEM_INVALID_HOOK_DATA);

        address _asset = IERC4626(_redeemData.vault).asset();

        bool _useDynamicAmount = _redeemData.shares == USE_PREVIOUS_HOOK_OUTPUT;

        if (_useDynamicAmount) {
            require(_previousHook != address(0), HOOK4626REDEEM_PREVIOUS_HOOK_NO_OUTPUT);

            // [getDynamicAmount, approve, redeem, resetApproval, (optional) validate]
            uint256 _execCount = _redeemData.minAssets > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.resolveDynamicAmount.selector, _previousHook, _redeemData.vault, _asset, _redeemData.owner
                )
            });

            _executions[1] = Execution({
                target: _redeemData.vault,
                value: 0,
                callData: abi.encodeWithSelector(IERC20.approve.selector, address(this), _redeemData.shares)
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.executeRedeem.selector, _redeemData.receiver)
            });

            // Clear unlimited approval after use
            _executions[3] = Execution({
                target: _redeemData.vault,
                value: 0,
                callData: abi.encodeWithSelector(IERC20.approve.selector, address(this), uint256(0))
            });

            if (_redeemData.minAssets > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinAssets.selector, _redeemData.minAssets)
                });
            }
        } else {
            require(_redeemData.shares > 0, HOOK4626REDEEM_INVALID_HOOK_DATA);

            // [snapshot, redeem, storeContext, (optional) validate]
            uint256 _execCount = _redeemData.minAssets > 0 ? 4 : 3;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.snapshotBalance.selector, _asset, _redeemData.receiver)
            });

            _executions[1] = Execution({
                target: _redeemData.vault,
                value: 0,
                callData: abi.encodeWithSelector(
                    IERC4626.redeem.selector, _redeemData.shares, _redeemData.receiver, _redeemData.owner
                )
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.storeRedeemContextStatic.selector,
                    _redeemData.vault,
                    _asset,
                    _redeemData.shares,
                    _redeemData.receiver,
                    _redeemData.owner
                )
            });

            if (_redeemData.minAssets > 0) {
                _executions[3] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinAssets.selector, _redeemData.minAssets)
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

        delete _redeemContext;
        delete _preActionBalance;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
    function getOutputAmount() external view override returns (uint256 _outputAmount) {
        return _redeemContext.assetsReceived;
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT RESOLUTION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Resolve the dynamic amount from the previous hook
    /// @dev Called during execution to get amount from previous hook's output
    /// @param _previousHook The address of the previous hook
    /// @param _vault The vault address (stored for later use)
    /// @param _asset The asset address (stored for later use)
    /// @param _owner The owner of the shares (stored for later use)
    function resolveDynamicAmount(
        address _previousHook,
        address _vault,
        address _asset,
        address _owner
    )
        external
        onlyOwner
    {
        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOK4626REDEEM_INVALID_HOOK_DATA);

        _redeemContext = RedeemContext({
            vault: _vault,
            asset: _asset,
            sharesRedeemed: _amount,
            assetsReceived: 0,
            receiver: address(0),
            owner: _owner,
            timestamp: block.timestamp
        });
    }

    /// @notice Snapshot the receiver's asset balance before a static redeem
    /// @dev Called before the vault.redeem() execution to enable delta computation
    /// @param _token The asset token to snapshot
    /// @param _account The account whose balance to snapshot
    function snapshotBalance(address _token, address _account) external onlyOwner {
        _preActionBalance = IERC20(_token).balanceOf(_account);
    }

    /// @notice Execute the redemption (for dynamic amount flow)
    /// @param _receiver The address to receive the assets
    function executeRedeem(address _receiver) external onlyOwner {
        RedeemContext storage _ctx = _redeemContext;
        uint256 _assets = IERC4626(_ctx.vault).redeem(_ctx.sharesRedeemed, _receiver, _ctx.owner);
        _ctx.receiver = _receiver;
        _ctx.assetsReceived = _assets;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store redeem context after execution (for static amount flow)
    /// @dev Called as part of the execution chain to save context for next hook
    /// @dev Uses balance delta (current - snapshot) to correctly measure assets received
    /// @param _vault The vault address
    /// @param _asset The underlying asset address
    /// @param _sharesRedeemed The amount of shares redeemed
    /// @param _receiver The address that received assets
    /// @param _owner The owner of the redeemed shares
    function storeRedeemContextStatic(
        address _vault,
        address _asset,
        uint256 _sharesRedeemed,
        address _receiver,
        address _owner
    )
        external
        onlyOwner
    {
        uint256 _assetsReceived = IERC20(_asset).balanceOf(_receiver) - _preActionBalance;

        _redeemContext = RedeemContext({
            vault: _vault,
            asset: _asset,
            sharesRedeemed: _sharesRedeemed,
            assetsReceived: _assetsReceived,
            receiver: _receiver,
            owner: _owner,
            timestamp: block.timestamp
        });
    }

    /* ///////////////////////////////////////////////////////////////
                         VALIDATION HELPERS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Validates that the redemption produced at least the minimum expected assets
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param _minAssets The minimum expected assets
    function validateMinAssets(uint256 _minAssets) external view onlyOwner {
        require(_redeemContext.assetsReceived >= _minAssets, HOOK4626REDEEM_INSUFFICIENT_ASSETS);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if the hook has an active execution context
    /// @return _hasContext Whether there is an active execution context
    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    /// @notice Get the stored redeem context
    /// @return _context The stored redeem context
    function getRedeemContext() external view returns (RedeemContext memory _context) {
        return _redeemContext;
    }

    /// @notice Get the vault address from the last redemption
    /// @return _vault The vault address
    function getLastVault() external view returns (address _vault) {
        return _redeemContext.vault;
    }

    /// @notice Get the assets received from the last redemption
    /// @return _assets The amount of assets received
    function getLastAssetsReceived() external view returns (uint256 _assets) {
        return _redeemContext.assetsReceived;
    }

    /// @notice Get the shares redeemed in the last operation
    /// @return _shares The amount of shares redeemed
    function getLastSharesRedeemed() external view returns (uint256 _shares) {
        return _redeemContext.sharesRedeemed;
    }

    /// @notice Get the underlying asset from the last redemption
    /// @return _asset The underlying asset address
    function getLastAsset() external view returns (address _asset) {
        return _redeemContext.asset;
    }

    /// @notice Preview the assets that would be received for a redemption
    /// @param _vault The vault address
    /// @param _shares The amount of shares to redeem
    /// @return _assets The expected assets to be received
    function previewRedeem(address _vault, uint256 _shares) external view returns (uint256 _assets) {
        return IERC4626(_vault).previewRedeem(_shares);
    }

    /// @notice Get the maximum shares that can be redeemed
    /// @param _vault The vault address
    /// @param _owner The owner address
    /// @return _maxShares The maximum shares that can be redeemed
    function maxRedeem(address _vault, address _owner) external view returns (uint256 _maxShares) {
        return IERC4626(_vault).maxRedeem(_owner);
    }
}
