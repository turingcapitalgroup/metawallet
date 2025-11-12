// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/// @title ERC4626RedeemHook
/// @notice Hook for redeeming shares from ERC4626 vaults
/// @dev This hook performs the redeem operation which burns shares to receive underlying assets
///      This is an OUTFLOW hook as it decreases the vault share balance
///      Stores execution context that can be read by subsequent hooks in the chain
contract ERC4626RedeemHook is IHook {
    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Unique identifier for this hook type
    bytes32 public constant HOOK_SUBTYPE = keccak256("ERC4626.Redeem");

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
    /// @dev Maps caller address to execution state
    mapping(address => bool) private _executionContext;

    /// @notice Stores redeem context data for each caller
    /// @dev Maps caller address to their latest redeem context
    /// @dev This allows subsequent hooks to access redemption details
    mapping(address => RedeemContext) private _redeemContext;

    /* ///////////////////////////////////////////////////////////////
                              ERRORS
    ///////////////////////////////////////////////////////////////*/

    error InvalidHookData();
    error HookNotInitialized();
    error HookAlreadyInitialized();

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for redeem operation
    /// @param vault The ERC4626 vault address
    /// @param shares The amount of shares to redeem
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

    /* ///////////////////////////////////////////////////////////////
                         IHOOK IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHook
    function buildExecutions(address previousHook, address smartAccount, bytes calldata data)
        external
        view
        override
        returns (Execution[] memory executions)
    {
        // Decode the hook data
        RedeemData memory redeemData = abi.decode(data, (RedeemData));

        // Validate inputs
        if (redeemData.vault == address(0)) revert InvalidHookData();
        if (redeemData.shares == 0) revert InvalidHookData();
        if (redeemData.receiver == address(0)) revert InvalidHookData();
        if (redeemData.owner == address(0)) revert InvalidHookData();

        // Get the underlying asset from the vault
        address asset = IERC4626(redeemData.vault).asset();

        // Build execution array: [redeem, storeContext, (optional) validate]
        uint256 execCount = redeemData.minAssets > 0 ? 3 : 2;
        executions = new Execution[](execCount);

        // Execution 0: Redeem shares from vault
        executions[0] = Execution({
            target: redeemData.vault,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC4626.redeem.selector, redeemData.shares, redeemData.receiver, redeemData.owner
            )
        });

        // Execution 1: Store context for next hook
        executions[1] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(
                this.storeRedeemContext.selector,
                smartAccount,
                redeemData.vault,
                asset,
                redeemData.shares,
                redeemData.receiver,
                redeemData.owner
            )
        });

        // Execution 2 (optional): Validate minimum assets received
        if (redeemData.minAssets > 0) {
            executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.validateMinAssets.selector, asset, redeemData.receiver, redeemData.minAssets
                )
            });
        }
    }

    /// @inheritdoc IHook
    function initializeHookContext(address caller) external override {
        if (_executionContext[caller]) revert HookAlreadyInitialized();
        _executionContext[caller] = true;
    }

    /// @inheritdoc IHook
    function finalizeHookContext(address caller) external override {
        if (!_executionContext[caller]) revert HookNotInitialized();
        _executionContext[caller] = false;

        // Clean up context data after execution completes
        delete _redeemContext[caller];
    }

    /// @inheritdoc IHook
    function getHookType() external pure override returns (HookType) {
        return HookType.OUTFLOW;
    }

    /// @inheritdoc IHook
    function getHookSubtype() external pure override returns (bytes32) {
        return HOOK_SUBTYPE;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store redeem context after execution
    /// @dev Called as part of the execution chain to save context for next hook
    /// @param caller The address executing the hook chain
    /// @param vault The vault address
    /// @param asset The underlying asset address
    /// @param sharesRedeemed The amount of shares redeemed
    /// @param receiver The address that received assets
    /// @param owner The owner of the redeemed shares
    function storeRedeemContext(
        address caller,
        address vault,
        address asset,
        uint256 sharesRedeemed,
        address receiver,
        address owner
    )
        external
    {
        // Get actual assets received
        uint256 assetsReceived = IERC20(asset).balanceOf(receiver);

        // Store context
        _redeemContext[caller] = RedeemContext({
            vault: vault,
            asset: asset,
            sharesRedeemed: sharesRedeemed,
            assetsReceived: assetsReceived,
            receiver: receiver,
            owner: owner,
            timestamp: block.timestamp
        });
    }

    /* ///////////////////////////////////////////////////////////////
                         VALIDATION HELPERS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Validates that the receiver has at least the minimum expected assets
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param asset The asset token address
    /// @param receiver The address to check balance for
    /// @param minAssets The minimum expected assets
    function validateMinAssets(address asset, address receiver, uint256 minAssets) external view {
        uint256 balance = IERC20(asset).balanceOf(receiver);
        require(balance >= minAssets, "ERC4626RedeemHook: Insufficient assets received");
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if a caller has an active execution context
    /// @param caller The address to check
    /// @return Whether the caller has an active execution context
    function hasActiveContext(address caller) external view returns (bool) {
        return _executionContext[caller];
    }

    /// @notice Get the stored redeem context for a caller
    /// @dev Returns the context from the last redeem operation
    /// @dev This allows subsequent hooks to access redemption information
    /// @param caller The address to get context for
    /// @return context The stored redeem context
    function getRedeemContext(address caller) external view returns (RedeemContext memory context) {
        return _redeemContext[caller];
    }

    /// @notice Get the vault address from the last redemption
    /// @param caller The address to check
    /// @return vault The vault address
    function getLastVault(address caller) external view returns (address vault) {
        return _redeemContext[caller].vault;
    }

    /// @notice Get the assets received from the last redemption
    /// @param caller The address to check
    /// @return assets The amount of assets received
    function getLastAssetsReceived(address caller) external view returns (uint256 assets) {
        return _redeemContext[caller].assetsReceived;
    }

    /// @notice Get the shares redeemed in the last operation
    /// @param caller The address to check
    /// @return shares The amount of shares redeemed
    function getLastSharesRedeemed(address caller) external view returns (uint256 shares) {
        return _redeemContext[caller].sharesRedeemed;
    }

    /// @notice Get the underlying asset from the last redemption
    /// @param caller The address to check
    /// @return asset The underlying asset address
    function getLastAsset(address caller) external view returns (address asset) {
        return _redeemContext[caller].asset;
    }

    /// @notice Preview the assets that would be received for a redemption
    /// @param vault The vault address
    /// @param shares The amount of shares to redeem
    /// @return assets The expected assets to be received
    function previewRedeem(address vault, uint256 shares) external view returns (uint256 assets) {
        return IERC4626(vault).previewRedeem(shares);
    }

    /// @notice Get the maximum shares that can be redeemed
    /// @param vault The vault address
    /// @param owner The owner address
    /// @return maxShares The maximum shares that can be redeemed
    function maxRedeem(address vault, address owner) external view returns (uint256 maxShares) {
        return IERC4626(vault).maxRedeem(owner);
    }
}
