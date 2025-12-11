// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Local Interfaces
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { IHookResult } from "metawallet/src/interfaces/IHookResult.sol";

// External Libraries
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

// Local Errors
import {
    HOOK4626DEPOSIT_INSUFFICIENT_SHARES,
    HOOK4626DEPOSIT_INVALID_HOOK_DATA,
    HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND
} from "metawallet/src/errors/Errors.sol";

/// @title ERC4626ApproveAndDepositHook
/// @notice Hook for approving and depositing assets into ERC4626 vaults
/// @dev This hook performs two operations:
///      1. Approves the vault to spend the underlying asset
///      2. Deposits the assets into the vault
///      This is an INFLOW hook as it increases the vault share balance
///      Stores execution context that can be read by subsequent hooks in the chain
///      Supports dynamic amounts by reading from previous hook's output
contract ERC4626ApproveAndDepositHook is IHook, IHookResult, Ownable {
    using SafeTransferLib for address;

    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Special value indicating amount should be read from previous hook
    uint256 public constant USE_PREVIOUS_HOOK_OUTPUT = type(uint256).max;

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
    bool private _executionContext;

    /// @notice Stores deposit context data for each caller
    /// @dev Maps caller address to their latest deposit context
    /// @dev This allows subsequent hooks to access deposit details
    DepositContext private _depositContext;

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for approve and deposit operation
    /// @param vault The ERC4626 vault address
    /// @param assets The amount of underlying assets to deposit (use USE_PREVIOUS_HOOK_OUTPUT for dynamic)
    /// @param receiver The address that will receive the vault shares
    /// @param minShares Minimum shares expected (slippage protection)
    struct ApproveAndDepositData {
        address vault;
        uint256 assets;
        address receiver;
        uint256 minShares;
    }

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOK IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHook
    /// @param _previousHook The address of the previous hook in the chain
    /// @param _data Encoded ApproveAndDepositData
    /// @return _executions Array of executions to perform
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
        // Decode the hook data
        ApproveAndDepositData memory _depositData = abi.decode(_data, (ApproveAndDepositData));

        // Validate inputs
        require(_depositData.vault != address(0), HOOK4626DEPOSIT_INVALID_HOOK_DATA);
        require(_depositData.receiver != address(0), HOOK4626DEPOSIT_INVALID_HOOK_DATA);

        // Get the underlying asset from the vault
        address _asset = IERC4626(_depositData.vault).asset();

        // Determine the actual amount to deposit
        bool _useDynamicAmount = _depositData.assets == USE_PREVIOUS_HOOK_OUTPUT;

        if (_useDynamicAmount) {
            // Amount will be read from previous hook at execution time
            // NOTE: Tokens should already be at this hook, sent by the previous hook
            require(_previousHook != address(0), HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND);

            // Build execution array with dynamic amount resolution
            // [getDynamicAmount, approveVault, deposit, storeContext, (optional) validate]
            uint256 _execCount = _depositData.minShares > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            // Execution 0: Get amount from previous hook
            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.resolveDynamicAmount.selector, _previousHook, _depositData.vault, _asset
                )
            });

            // Execution 1: Approve vault to spend assets using safeApproveWithRetry
            _executions[1] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.approveForDeposit.selector, _depositData.vault)
            });

            // Execution 2: Deposit assets into vault (amount will be resolved at runtime)
            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.executeDeposit.selector, _depositData.receiver)
            });

            // Execution 3: Store context for next hook
            _executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.storeDepositContext.selector, _depositData.receiver)
            });

            // Execution 4 (optional): Validate minimum shares received
            if (_depositData.minShares > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(
                        this.validateMinShares.selector,
                        _depositData.vault,
                        _depositData.receiver,
                        _depositData.minShares
                    )
                });
            }
        } else {
            // Static amount provided
            require(_depositData.assets > 0, HOOK4626DEPOSIT_INVALID_HOOK_DATA);

            // Build execution array: [transfer, approve, deposit, storeContext, (optional) validate]
            uint256 _execCount = _depositData.minShares > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            // Execution 0: Transfer assets from metawallet to hook
            _executions[0] = Execution({
                target: _asset,
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(this), _depositData.assets)
            });

            // Execution 1: Approve vault to spend assets using safeApproveWithRetry
            _executions[1] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.approveForDepositStatic.selector, _asset, _depositData.vault, _depositData.assets
                )
            });

            // Execution 2: Deposit assets into vault (hook deposits on behalf of receiver)
            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.executeDepositStatic.selector, _depositData.vault, _depositData.assets, _depositData.receiver
                )
            });

            // Execution 3: Store context for next hook
            _executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.storeDepositContextStatic.selector,
                    _depositData.vault,
                    _asset,
                    _depositData.assets,
                    _depositData.receiver
                )
            });

            // Execution 4 (optional): Validate minimum shares received
            if (_depositData.minShares > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(
                        this.validateMinShares.selector,
                        _depositData.vault,
                        _depositData.receiver,
                        _depositData.minShares
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
        delete _depositContext;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
    /// @return _outputAmount The amount of shares received from the deposit
    function getOutputAmount() external view override returns (uint256 _outputAmount) {
        return _depositContext.sharesReceived;
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT RESOLUTION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Resolve the dynamic amount from the previous hook
    /// @dev Called during execution to get amount from previous hook's output
    /// @param _previousHook The address of the previous hook
    /// @param _vault The vault address (stored for later use)
    /// @param _asset The asset address (stored for later use)
    function resolveDynamicAmount(address _previousHook, address _vault, address _asset) external onlyOwner {
        // Get amount from previous hook
        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOK4626DEPOSIT_INVALID_HOOK_DATA);

        // Store temporary context with the resolved amount
        _depositContext = DepositContext({
            vault: _vault,
            asset: _asset,
            assetsDeposited: _amount,
            sharesReceived: 0, // Will be updated after deposit
            receiver: address(0), // Will be updated after deposit
            timestamp: block.timestamp
        });
    }

    /// @notice Approve the vault to spend assets (for dynamic amount flow)
    /// @param _vault The vault address
    function approveForDeposit(address _vault) external onlyOwner {
        DepositContext memory _ctx = _depositContext;
        _ctx.asset.safeApproveWithRetry(_vault, _ctx.assetsDeposited);
    }

    /// @notice Approve the vault to spend assets (for static amount flow)
    /// @param _asset The asset address to approve
    /// @param _vault The vault address (spender)
    /// @param _amount The amount to approve
    function approveForDepositStatic(address _asset, address _vault, uint256 _amount) external onlyOwner {
        _asset.safeApproveWithRetry(_vault, _amount);
    }

    /// @notice Execute the deposit (for dynamic amount flow)
    /// @param _receiver The address to receive the shares
    function executeDeposit(address _receiver) external onlyOwner {
        DepositContext storage _ctx = _depositContext;
        IERC4626(_ctx.vault).deposit(_ctx.assetsDeposited, _receiver);
        _ctx.receiver = _receiver;
    }

    /// @notice Execute the deposit (for static amount flow)
    /// @param _vault The vault address
    /// @param _assets The amount of assets to deposit
    /// @param _receiver The address to receive the shares
    function executeDepositStatic(address _vault, uint256 _assets, address _receiver) external onlyOwner {
        IERC4626(_vault).deposit(_assets, _receiver);
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store deposit context after execution (for dynamic amount flow)
    /// @dev Called as part of the execution chain to save final context
    /// @param _receiver The address that received shares
    function storeDepositContext(address _receiver) external onlyOwner {
        DepositContext storage _ctx = _depositContext;

        // Get actual shares received
        uint256 _sharesReceived = IERC20(_ctx.vault).balanceOf(_receiver);

        // Update context with final shares
        _ctx.sharesReceived = _sharesReceived;
    }

    /// @notice Store deposit context after execution (for static amount flow)
    /// @dev Called as part of the execution chain to save context for next hook
    /// @param _vault The vault address
    /// @param _asset The underlying asset address
    /// @param _assetsDeposited The amount of assets deposited
    /// @param _receiver The address that received shares
    function storeDepositContextStatic(
        address _vault,
        address _asset,
        uint256 _assetsDeposited,
        address _receiver
    )
        external
        onlyOwner
    {
        // Get actual shares received
        uint256 _sharesReceived = IERC20(_vault).balanceOf(_receiver);

        // Store context
        _depositContext = DepositContext({
            vault: _vault,
            asset: _asset,
            assetsDeposited: _assetsDeposited,
            sharesReceived: _sharesReceived,
            receiver: _receiver,
            timestamp: block.timestamp
        });
    }

    /* ///////////////////////////////////////////////////////////////
                         VALIDATION HELPERS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Validates that the receiver has at least the minimum expected shares
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param _vault The vault to check
    /// @param _receiver The address to check balance for
    /// @param _minShares The minimum expected shares
    function validateMinShares(address _vault, address _receiver, uint256 _minShares) external view onlyOwner {
        uint256 _shares = IERC20(_vault).balanceOf(_receiver);
        require(_shares >= _minShares, HOOK4626DEPOSIT_INSUFFICIENT_SHARES);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if a caller has an active execution context
    /// @return _hasContext Whether the caller has an active execution context
    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    /// @notice Get the stored deposit context for a caller
    /// @dev Returns the context from the last deposit operation
    /// @dev This allows subsequent hooks to access deposit information
    /// @return _context The stored deposit context
    function getDepositContext() external view returns (DepositContext memory _context) {
        return _depositContext;
    }

    /// @notice Get the vault address from the last deposit
    /// @return _vault The vault address
    function getLastVault() external view returns (address _vault) {
        return _depositContext.vault;
    }

    /// @notice Get the shares received from the last deposit
    /// @return _shares The amount of shares received
    function getLastSharesReceived() external view returns (uint256 _shares) {
        return _depositContext.sharesReceived;
    }

    /// @notice Get the assets deposited in the last operation
    /// @return _assets The amount of assets deposited
    function getLastAssetsDeposited() external view returns (uint256 _assets) {
        return _depositContext.assetsDeposited;
    }

    /// @notice Preview the shares that would be received for a deposit
    /// @param _vault The vault address
    /// @param _assets The amount of assets to deposit
    /// @return _shares The expected shares to be received
    function previewDeposit(address _vault, uint256 _assets) external view returns (uint256 _shares) {
        return IERC4626(_vault).previewDeposit(_assets);
    }

    /// @notice Get the maximum assets that can be deposited
    /// @param _vault The vault address
    /// @param _receiver The receiver address
    /// @return _maxAssets The maximum assets that can be deposited
    function maxDeposit(address _vault, address _receiver) external view returns (uint256 _maxAssets) {
        return IERC4626(_vault).maxDeposit(_receiver);
    }
}
