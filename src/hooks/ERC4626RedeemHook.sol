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
    HOOK4626REDEEM_HOOK_ALREADY_INITIALIZED,
    HOOK4626REDEEM_HOOK_NOT_INITIALIZED,
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

    /// @notice Unique identifier for this hook type
    bytes32 public constant HOOK_SUBTYPE = keccak256("ERC4626.Redeem");

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

    /// @notice Tracks execution context per caller
    bool private _executionContext;

    /// @notice Stores redeem context data for each caller
    /// @dev This allows subsequent hooks to access redemption details
    RedeemContext private _redeemContext;

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

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOK IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHook
    /// @param _previousHook The address of the previous hook in the chain
    /// @param _data Encoded RedeemData
    /// @return _executions Array of executions to perform
    function buildExecutions(address _previousHook, bytes calldata _data)
        external
        view
        override
        onlyOwner
        returns (Execution[] memory _executions)
    {
        // Decode the hook data
        RedeemData memory _redeemData = abi.decode(_data, (RedeemData));

        // Validate inputs
        require(_redeemData.vault != address(0), HOOK4626REDEEM_INVALID_HOOK_DATA);
        require(_redeemData.receiver != address(0), HOOK4626REDEEM_INVALID_HOOK_DATA);
        require(_redeemData.owner != address(0), HOOK4626REDEEM_INVALID_HOOK_DATA);

        // Get the underlying asset from the vault
        address _asset = IERC4626(_redeemData.vault).asset();

        // Determine if using dynamic amount
        bool _useDynamicAmount = _redeemData.shares == USE_PREVIOUS_HOOK_OUTPUT;

        if (_useDynamicAmount) {
            // Amount will be read from previous hook at execution time
            require(_previousHook != address(0), HOOK4626REDEEM_PREVIOUS_HOOK_NO_OUTPUT);

            // Build execution array with dynamic amount resolution
            // [getDynamicAmount, redeem, storeContext, (optional) validate]
            uint256 _execCount = _redeemData.minAssets > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            // Execution 0: Get amount from previous hook
            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.resolveDynamicAmount.selector, _previousHook, _redeemData.vault, _asset, _redeemData.owner
                )
            });

            // Execution 1: Approve vault shares to hook
            _executions[1] = Execution({
                target: _redeemData.vault, // vault address
                value: 0,
                callData: abi.encodeWithSelector(IERC20.approve.selector, address(this), _redeemData.shares)
            });

            // Execution 2: Redeem shares from vault (amount will be resolved at runtime)
            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.executeRedeem.selector, _redeemData.receiver)
            });

            // Execution 3: Store context for next hook
            _executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.storeRedeemContext.selector, _redeemData.receiver)
            });

            // Execution 4 (optional): Validate minimum assets received
            if (_redeemData.minAssets > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(
                        this.validateMinAssets.selector, _asset, _redeemData.receiver, _redeemData.minAssets
                    )
                });
            }
        } else {
            // Static amount provided
            require(_redeemData.shares > 0, HOOK4626REDEEM_INVALID_HOOK_DATA);

            // Build execution array: [redeem, storeContext, (optional) validate]
            uint256 _execCount = _redeemData.minAssets > 0 ? 3 : 2;
            _executions = new Execution[](_execCount);

            // Execution 0: Redeem shares from vault
            _executions[0] = Execution({
                target: _redeemData.vault,
                value: 0,
                callData: abi.encodeWithSelector(
                    IERC4626.redeem.selector, _redeemData.shares, _redeemData.receiver, _redeemData.owner
                )
            });

            // Execution 1: Store context for next hook
            _executions[1] = Execution({
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

            // Execution 2 (optional): Validate minimum assets received
            if (_redeemData.minAssets > 0) {
                _executions[2] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(
                        this.validateMinAssets.selector, _asset, _redeemData.receiver, _redeemData.minAssets
                    )
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

        // Clean up context data after execution completes
        delete _redeemContext;
    }

    /// @inheritdoc IHook
    /// @return _hookType The type of hook (OUTFLOW)
    function getHookType() external pure override returns (HookType _hookType) {
        return HookType.OUTFLOW;
    }

    /// @inheritdoc IHook
    /// @return _subtype The subtype identifier for this hook
    function getHookSubtype() external pure override returns (bytes32 _subtype) {
        return HOOK_SUBTYPE;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
    /// @return _outputAmount The amount of assets received from the redemption
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
    function resolveDynamicAmount(address _previousHook, address _vault, address _asset, address _owner) external {
        // Get amount from previous hook
        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOK4626REDEEM_INVALID_HOOK_DATA);

        // Store temporary context with the resolved amount
        _redeemContext = RedeemContext({
            vault: _vault,
            asset: _asset,
            sharesRedeemed: _amount,
            assetsReceived: 0, // Will be updated after redeem
            receiver: address(0), // Will be updated after redeem
            owner: _owner,
            timestamp: block.timestamp
        });
    }

    /// @notice Execute the redemption (for dynamic amount flow)
    /// @param _receiver The address to receive the assets
    function executeRedeem(address _receiver) external onlyOwner {
        RedeemContext storage _ctx = _redeemContext;
        IERC4626(_ctx.vault).redeem(_ctx.sharesRedeemed, _receiver, _ctx.owner);
        _ctx.receiver = _receiver;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store redeem context after execution (for dynamic amount flow)
    /// @dev Called as part of the execution chain to save final context
    /// @param _receiver The address that received assets
    function storeRedeemContext(address _receiver) external onlyOwner {
        RedeemContext storage _ctx = _redeemContext;

        // Get actual assets received
        uint256 _assetsReceived = IERC20(_ctx.asset).balanceOf(_receiver);

        // Update context with final assets
        _ctx.assetsReceived = _assetsReceived;
    }

    /// @notice Store redeem context after execution (for static amount flow)
    /// @dev Called as part of the execution chain to save context for next hook
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
        // Get actual assets received
        uint256 _assetsReceived = IERC20(_asset).balanceOf(_receiver);

        // Store context
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

    /// @notice Validates that the receiver has at least the minimum expected assets
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param _asset The asset token address
    /// @param _receiver The address to check balance for
    /// @param _minAssets The minimum expected assets
    function validateMinAssets(address _asset, address _receiver, uint256 _minAssets) external view onlyOwner {
        uint256 _balance = IERC20(_asset).balanceOf(_receiver);
        require(_balance >= _minAssets, HOOK4626REDEEM_INSUFFICIENT_ASSETS);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if a caller has an active execution context
    /// @return _hasContext Whether the caller has an active execution context
    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    /// @notice Get the stored redeem context for a caller
    /// @dev Returns the context from the last redeem operation
    /// @dev This allows subsequent hooks to access redemption information
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
