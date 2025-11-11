// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IHook } from "./interfaces/IHook.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/// @title ERC4626ApproveAndDepositHook
/// @notice Hook for approving and depositing assets into ERC4626 vaults
/// @dev This hook performs two operations:
///      1. Approves the vault to spend the underlying asset
///      2. Deposits the assets into the vault
///      This is an INFLOW hook as it increases the vault share balance
///      Stores execution context that can be read by subsequent hooks in the chain
contract ERC4626ApproveAndDepositHook is IHook {
    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Unique identifier for this hook type
    bytes32 public constant HOOK_SUBTYPE = keccak256("ERC4626.ApproveAndDeposit");

    /* ///////////////////////////////////////////////////////////////
                              STRUCTURES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Context data stored during execution for hook chaining
    /// @param vault The vault address that was deposited into
    /// @param asset The underlying asset address
    /// @param assetsDeposited The amount of assets deposited
    /// @param sharesReceived The amount of shares received from deposit
    /// @param receiver The address that received the shares
    /// @param timestamp The timestamp of the deposit
    struct DepositContext {
        address vault;
        address asset;
        uint256 assetsDeposited;
        uint256 sharesReceived;
        address receiver;
        uint256 timestamp;
    }

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Tracks execution context per caller
    /// @dev Maps caller address to execution state
    mapping(address => bool) private _executionContext;

    /// @notice Stores deposit context data for each caller
    /// @dev Maps caller address to their latest deposit context
    /// @dev This allows subsequent hooks to access deposit details
    mapping(address => DepositContext) private _depositContext;

    /* ///////////////////////////////////////////////////////////////
                              ERRORS
    ///////////////////////////////////////////////////////////////*/

    error InvalidHookData();
    error HookNotInitialized();
    error HookAlreadyInitialized();

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for approve and deposit operation
    /// @param vault The ERC4626 vault address
    /// @param assets The amount of underlying assets to deposit
    /// @param receiver The address that will receive the vault shares
    /// @param minShares Minimum shares expected (slippage protection)
    struct ApproveAndDepositData {
        address vault;
        uint256 assets;
        address receiver;
        uint256 minShares;
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
        ApproveAndDepositData memory depositData = abi.decode(data, (ApproveAndDepositData));

        // Validate inputs
        if (depositData.vault == address(0)) revert InvalidHookData();
        if (depositData.assets == 0) revert InvalidHookData();
        if (depositData.receiver == address(0)) revert InvalidHookData();

        // Get the underlying asset from the vault
        address asset = IERC4626(depositData.vault).asset();

        // Build execution array: [approve, deposit, storeContext, (optional) validate]
        uint256 execCount = depositData.minShares > 0 ? 4 : 3;
        executions = new Execution[](execCount);

        // Execution 0: Approve vault to spend assets
        executions[0] = Execution({
            target: asset,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.approve.selector,
                depositData.vault,
                depositData.assets
            )
        });

        // Execution 1: Deposit assets into vault
        executions[1] = Execution({
            target: depositData.vault,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC4626.deposit.selector,
                depositData.assets,
                depositData.receiver
            )
        });

        // Execution 2: Store context for next hook
        executions[2] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(
                this.storeDepositContext.selector,
                smartAccount,
                depositData.vault,
                asset,
                depositData.assets,
                depositData.receiver
            )
        });

        // Execution 3 (optional): Validate minimum shares received
        if (depositData.minShares > 0) {
            executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.validateMinShares.selector,
                    depositData.vault,
                    depositData.receiver,
                    depositData.minShares
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
        delete _depositContext[caller];
    }

    /// @inheritdoc IHook
    function getHookType() external pure override returns (HookType) {
        return HookType.INFLOW;
    }

    /// @inheritdoc IHook
    function getHookSubtype() external pure override returns (bytes32) {
        return HOOK_SUBTYPE;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store deposit context after execution
    /// @dev Called as part of the execution chain to save context for next hook
    /// @param caller The address executing the hook chain
    /// @param vault The vault address
    /// @param asset The underlying asset address
    /// @param assetsDeposited The amount of assets deposited
    /// @param receiver The address that received shares
    function storeDepositContext(
        address caller,
        address vault,
        address asset,
        uint256 assetsDeposited,
        address receiver
    ) external {
        // Get actual shares received
        uint256 sharesReceived = IERC20(vault).balanceOf(receiver);
        
        // Store context
        _depositContext[caller] = DepositContext({
            vault: vault,
            asset: asset,
            assetsDeposited: assetsDeposited,
            sharesReceived: sharesReceived,
            receiver: receiver,
            timestamp: block.timestamp
        });
    }

    /* ///////////////////////////////////////////////////////////////
                         VALIDATION HELPERS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Validates that the receiver has at least the minimum expected shares
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param vault The vault to check
    /// @param receiver The address to check balance for
    /// @param minShares The minimum expected shares
    function validateMinShares(address vault, address receiver, uint256 minShares) external view {
        uint256 shares = IERC20(vault).balanceOf(receiver);
        require(shares >= minShares, "ERC4626ApproveAndDepositHook: Insufficient shares received");
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

    /// @notice Get the stored deposit context for a caller
    /// @dev Returns the context from the last deposit operation
    /// @dev This allows subsequent hooks to access deposit information
    /// @param caller The address to get context for
    /// @return context The stored deposit context
    function getDepositContext(address caller) external view returns (DepositContext memory context) {
        return _depositContext[caller];
    }

    /// @notice Get the vault address from the last deposit
    /// @param caller The address to check
    /// @return vault The vault address
    function getLastVault(address caller) external view returns (address vault) {
        return _depositContext[caller].vault;
    }

    /// @notice Get the shares received from the last deposit
    /// @param caller The address to check
    /// @return shares The amount of shares received
    function getLastSharesReceived(address caller) external view returns (uint256 shares) {
        return _depositContext[caller].sharesReceived;
    }

    /// @notice Get the assets deposited in the last operation
    /// @param caller The address to check
    /// @return assets The amount of assets deposited
    function getLastAssetsDeposited(address caller) external view returns (uint256 assets) {
        return _depositContext[caller].assetsDeposited;
    }

    /// @notice Preview the shares that would be received for a deposit
    /// @param vault The vault address
    /// @param assets The amount of assets to deposit
    /// @return shares The expected shares to be received
    function previewDeposit(address vault, uint256 assets) external view returns (uint256 shares) {
        return IERC4626(vault).previewDeposit(assets);
    }

    /// @notice Get the maximum assets that can be deposited
    /// @param vault The vault address
    /// @param receiver The receiver address
    /// @return maxAssets The maximum assets that can be deposited
    function maxDeposit(address vault, address receiver) external view returns (uint256 maxAssets) {
        return IERC4626(vault).maxDeposit(receiver);
    }
}
