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

    /// @notice Tracks whether the hook is currently executing
    bool private _executionContext;

    /// @notice Stores deposit context data for the current execution
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
        ApproveAndDepositData memory _depositData = abi.decode(_data, (ApproveAndDepositData));

        require(_depositData.vault != address(0), HOOK4626DEPOSIT_INVALID_HOOK_DATA);
        require(_depositData.receiver != address(0), HOOK4626DEPOSIT_INVALID_HOOK_DATA);

        address _asset = IERC4626(_depositData.vault).asset();

        bool _useDynamicAmount = _depositData.assets == USE_PREVIOUS_HOOK_OUTPUT;

        if (_useDynamicAmount) {
            require(_previousHook != address(0), HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND);

            // [getDynamicAmount, approveVault, deposit, (optional) validate]
            uint256 _execCount = _depositData.minShares > 0 ? 4 : 3;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.resolveDynamicAmount.selector, _previousHook, _depositData.vault, _asset
                )
            });

            _executions[1] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.approveForDeposit.selector, _depositData.vault)
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.executeDeposit.selector, _depositData.receiver)
            });
            if (_depositData.minShares > 0) {
                _executions[3] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinShares.selector, _depositData.minShares)
                });
            }
        } else {
            require(_depositData.assets > 0, HOOK4626DEPOSIT_INVALID_HOOK_DATA);

            // [transfer, approve, deposit, storeContext, (optional) validate]
            uint256 _execCount = _depositData.minShares > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            _executions[0] = Execution({
                target: _asset,
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(this), _depositData.assets)
            });

            _executions[1] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.approveForDepositStatic.selector, _asset, _depositData.vault, _depositData.assets
                )
            });

            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.executeDepositStatic.selector, _depositData.vault, _depositData.assets, _depositData.receiver
                )
            });

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

            if (_depositData.minShares > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinShares.selector, _depositData.minShares)
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

        delete _depositContext;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
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
        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOK4626DEPOSIT_INVALID_HOOK_DATA);

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
        uint256 _shares = IERC4626(_ctx.vault).deposit(_ctx.assetsDeposited, _receiver);
        _ctx.receiver = _receiver;
        _ctx.sharesReceived = _shares;
    }

    /// @notice Execute the deposit (for static amount flow)
    /// @param _vault The vault address
    /// @param _assets The amount of assets to deposit
    /// @param _receiver The address to receive the shares
    function executeDepositStatic(address _vault, uint256 _assets, address _receiver) external onlyOwner {
        uint256 _shares = IERC4626(_vault).deposit(_assets, _receiver);
        _depositContext.sharesReceived = _shares;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store deposit context after execution (for static amount flow)
    /// @dev Called as part of the execution chain to save context for next hook
    /// @dev sharesReceived is already set in executeDepositStatic from the vault.deposit() return value
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
        uint256 _sharesReceived = _depositContext.sharesReceived;

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

    /// @notice Validates that the deposit produced at least the minimum expected shares
    /// @dev This function is called as part of the execution chain for slippage protection
    /// @param _minShares The minimum expected shares
    function validateMinShares(uint256 _minShares) external view onlyOwner {
        require(_depositContext.sharesReceived >= _minShares, HOOK4626DEPOSIT_INSUFFICIENT_SHARES);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if the hook has an active execution context
    /// @return _hasContext Whether there is an active execution context
    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    /// @notice Get the stored deposit context
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
