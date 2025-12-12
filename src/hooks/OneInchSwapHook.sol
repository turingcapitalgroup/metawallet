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

// Local Errors
import {
    HOOKONEINCH_INSUFFICIENT_OUTPUT,
    HOOKONEINCH_INVALID_HOOK_DATA,
    HOOKONEINCH_INVALID_ROUTER,
    HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND
} from "metawallet/src/errors/Errors.sol";

/// @title OneInchSwapHook
/// @notice Hook for performing token swaps via 1inch Aggregation Router
/// @dev This hook performs the following operations:
///      1. Approves the 1inch router to spend the input token
///      2. Executes the swap via the 1inch router using pre-built calldata
///      3. Validates minimum output amount (slippage protection)
///      Stores execution context that can be read by subsequent hooks in the chain
///      Supports dynamic amounts by reading from previous hook's output
contract OneInchSwapHook is IHook, IHookResult, Ownable {
    using SafeTransferLib for address;

    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Special value indicating amount should be read from previous hook
    uint256 public constant USE_PREVIOUS_HOOK_OUTPUT = type(uint256).max;

    /// @notice Native ETH sentinel address used by 1inch
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /* ///////////////////////////////////////////////////////////////
                              STRUCTURES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Context data stored during execution for hook chaining
    /// @param srcToken The source token address
    /// @param dstToken The destination token address
    /// @param amountIn The amount of source tokens swapped
    /// @param amountOut The amount of destination tokens received
    /// @param receiver The address that received the output tokens
    /// @param timestamp The timestamp of the swap
    struct SwapContext {
        address srcToken;
        address dstToken;
        uint256 amountIn;
        uint256 amountOut;
        address receiver;
        uint256 timestamp;
    }

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Tracks execution context per caller
    bool private _executionContext;

    /// @notice Stores swap context data for chaining
    SwapContext private _swapContext;

    /// @notice Temporary storage for dynamic swap execution
    address private _tempRouter;
    uint256 private _tempValue;
    bytes private _tempSwapCalldata;

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for 1inch swap operation
    /// @param router The 1inch aggregation router address
    /// @param srcToken The source token to swap from
    /// @param dstToken The destination token to swap to
    /// @param amountIn The amount of source tokens to swap (use USE_PREVIOUS_HOOK_OUTPUT for dynamic)
    /// @param minAmountOut Minimum amount of destination tokens expected (slippage protection)
    /// @param receiver The address that will receive the swapped tokens
    /// @param value The ETH value to send with the swap (for ETH-involved swaps)
    /// @param swapCalldata The pre-built calldata for the 1inch router swap function
    struct SwapData {
        address router;
        address srcToken;
        address dstToken;
        uint256 amountIn;
        uint256 minAmountOut;
        address receiver;
        uint256 value;
        bytes swapCalldata;
    }

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOK IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHook
    /// @param _previousHook The address of the previous hook in the chain
    /// @param _data Encoded SwapData
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
        SwapData memory _swapData = abi.decode(_data, (SwapData));

        // Validate inputs
        require(_swapData.router != address(0), HOOKONEINCH_INVALID_ROUTER);
        require(_swapData.srcToken != address(0), HOOKONEINCH_INVALID_HOOK_DATA);
        require(_swapData.dstToken != address(0), HOOKONEINCH_INVALID_HOOK_DATA);
        require(_swapData.receiver != address(0), HOOKONEINCH_INVALID_HOOK_DATA);
        require(_swapData.swapCalldata.length > 0, HOOKONEINCH_INVALID_HOOK_DATA);

        // Determine if using dynamic amount
        bool _useDynamicAmount = _swapData.amountIn == USE_PREVIOUS_HOOK_OUTPUT;

        if (_useDynamicAmount) {
            // Amount will be read from previous hook at execution time
            require(_previousHook != address(0), HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND);

            // Build execution array with dynamic amount resolution
            // [resolveDynamicAmount, approve, swap, storeContext, (optional) validate]
            uint256 _execCount = _swapData.minAmountOut > 0 ? 5 : 4;
            _executions = new Execution[](_execCount);

            // Execution 0: Get amount from previous hook
            _executions[0] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.resolveDynamicAmount.selector,
                    _previousHook,
                    _swapData.router,
                    _swapData.srcToken,
                    _swapData.dstToken,
                    _swapData.value,
                    _swapData.swapCalldata
                )
            });

            // Execution 1: Approve router to spend source tokens (amount resolved at runtime)
            _executions[1] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.approveForSwap.selector, _swapData.router)
            });

            // Execution 2: Execute the swap (uses stored context)
            _executions[2] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.executeSwap.selector, _swapData.receiver)
            });

            // Execution 3: Store context for next hook
            _executions[3] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.storeSwapContext.selector, _swapData.receiver)
            });

            // Execution 4 (optional): Validate minimum output received
            if (_swapData.minAmountOut > 0) {
                _executions[4] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(
                        this.validateMinOutput.selector, _swapData.dstToken, _swapData.receiver, _swapData.minAmountOut
                    )
                });
            }
        } else {
            // Static amount provided
            require(_swapData.amountIn > 0, HOOKONEINCH_INVALID_HOOK_DATA);

            // Check if swapping native ETH (no approval needed)
            bool _isNativeEth = _swapData.srcToken == NATIVE_ETH;

            // Build execution array: [approve (if not ETH), swap, storeContext, (optional) validate]
            uint256 _baseExecCount = _isNativeEth ? 2 : 3;
            uint256 _execCount = _swapData.minAmountOut > 0 ? _baseExecCount + 1 : _baseExecCount;
            _executions = new Execution[](_execCount);

            uint256 _idx = 0;

            // Execution: Approve router to spend source tokens (skip for native ETH)
            if (!_isNativeEth) {
                _executions[_idx++] = Execution({
                    target: _swapData.srcToken,
                    value: 0,
                    callData: abi.encodeWithSelector(IERC20.approve.selector, _swapData.router, _swapData.amountIn)
                });
            }

            // Execution: Execute the swap via 1inch router
            _executions[_idx++] =
                Execution({ target: _swapData.router, value: _swapData.value, callData: _swapData.swapCalldata });

            // Execution: Store context for next hook
            _executions[_idx++] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.storeSwapContextStatic.selector,
                    _swapData.srcToken,
                    _swapData.dstToken,
                    _swapData.amountIn,
                    _swapData.receiver
                )
            });

            // Execution (optional): Validate minimum output received
            if (_swapData.minAmountOut > 0) {
                _executions[_idx] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(
                        this.validateMinOutput.selector, _swapData.dstToken, _swapData.receiver, _swapData.minAmountOut
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
        delete _swapContext;
        delete _tempRouter;
        delete _tempValue;
        delete _tempSwapCalldata;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
    /// @return _outputAmount The amount of destination tokens received from the swap
    function getOutputAmount() external view override returns (uint256 _outputAmount) {
        return _swapContext.amountOut;
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT RESOLUTION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Resolve the dynamic amount from the previous hook
    /// @dev Called during execution to get amount from previous hook's output
    /// @param _previousHook The address of the previous hook
    /// @param _router The 1inch router address (stored for later use)
    /// @param _srcToken The source token address (stored for later use)
    /// @param _dstToken The destination token address (stored for later use)
    /// @param _value The ETH value to send with the swap (stored for later use)
    /// @param _swapCalldata The swap calldata (stored for later use)
    function resolveDynamicAmount(
        address _previousHook,
        address _router,
        address _srcToken,
        address _dstToken,
        uint256 _value,
        bytes calldata _swapCalldata
    )
        external
        onlyOwner
    {
        // Get amount from previous hook
        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOKONEINCH_INVALID_HOOK_DATA);

        // Store temporary context with the resolved amount
        _swapContext = SwapContext({
            srcToken: _srcToken,
            dstToken: _dstToken,
            amountIn: _amount,
            amountOut: 0, // Will be updated after swap
            receiver: address(0), // Will be updated after swap
            timestamp: block.timestamp
        });

        // Store additional data needed for execution
        _tempRouter = _router;
        _tempValue = _value;
        _tempSwapCalldata = _swapCalldata;
    }

    /// @notice Approve the router to spend source tokens (for dynamic amount flow)
    /// @param _router The 1inch router address
    function approveForSwap(address _router) external onlyOwner {
        SwapContext memory _ctx = _swapContext;
        (_ctx.srcToken).safeApproveWithRetry(_router, _ctx.amountIn);
    }

    /// @notice Execute the swap (for dynamic amount flow)
    /// @dev This function needs the router and swap calldata to be stored first via resolveDynamicAmount
    /// @param _receiver The address to receive the swapped tokens
    function executeSwap(address _receiver) external onlyOwner {
        SwapContext storage _ctx = _swapContext;

        // Load router address, value and calldata from storage
        address _router = _tempRouter;
        uint256 _value = _tempValue;
        bytes memory _calldata = _tempSwapCalldata;

        // Transfer tokens from hook to router (tokens were sent here by previous hook)
        // Then call the router with pre-built calldata
        // Note: For dynamic amounts, the swap calldata should use type(uint256).max
        // and the router will use the approved amount

        // Execute the swap - this will pull tokens from this hook via transferFrom
        (bool success,) = _router.call{ value: _value }(_calldata);
        require(success, HOOKONEINCH_INVALID_HOOK_DATA);

        // Update receiver in context
        _ctx.receiver = _receiver;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store swap context after execution (for dynamic amount flow)
    /// @param _receiver The address that received tokens
    function storeSwapContext(address _receiver) external onlyOwner {
        SwapContext storage _ctx = _swapContext;

        // Get actual output amount received
        uint256 _amountOut = IERC20(_ctx.dstToken).balanceOf(_receiver);

        // Update context with final output
        _ctx.amountOut = _amountOut;
        _ctx.receiver = _receiver;
    }

    /// @notice Store swap context after execution (for static amount flow)
    /// @param _srcToken The source token address
    /// @param _dstToken The destination token address
    /// @param _amountIn The amount of source tokens swapped
    /// @param _receiver The address that received tokens
    function storeSwapContextStatic(
        address _srcToken,
        address _dstToken,
        uint256 _amountIn,
        address _receiver
    )
        external
        onlyOwner
    {
        // Get actual output amount received
        uint256 _amountOut = IERC20(_dstToken).balanceOf(_receiver);

        // Store context
        _swapContext = SwapContext({
            srcToken: _srcToken,
            dstToken: _dstToken,
            amountIn: _amountIn,
            amountOut: _amountOut,
            receiver: _receiver,
            timestamp: block.timestamp
        });
    }

    /* ///////////////////////////////////////////////////////////////
                         VALIDATION HELPERS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Validates that the receiver has at least the minimum expected output
    /// @param _dstToken The destination token to check
    /// @param _receiver The address to check balance for
    /// @param _minAmountOut The minimum expected output amount
    function validateMinOutput(address _dstToken, address _receiver, uint256 _minAmountOut) external view onlyOwner {
        uint256 _balance = IERC20(_dstToken).balanceOf(_receiver);
        require(_balance >= _minAmountOut, HOOKONEINCH_INSUFFICIENT_OUTPUT);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if a caller has an active execution context
    /// @return _hasContext Whether the caller has an active execution context
    function hasActiveContext() external view returns (bool _hasContext) {
        return _executionContext;
    }

    /// @notice Get the stored swap context
    /// @return _context The stored swap context
    function getSwapContext() external view returns (SwapContext memory _context) {
        return _swapContext;
    }

    /// @notice Get the source token from the last swap
    /// @return _token The source token address
    function getLastSrcToken() external view returns (address _token) {
        return _swapContext.srcToken;
    }

    /// @notice Get the destination token from the last swap
    /// @return _token The destination token address
    function getLastDstToken() external view returns (address _token) {
        return _swapContext.dstToken;
    }

    /// @notice Get the amount of tokens received from the last swap
    /// @return _amount The amount of destination tokens received
    function getLastAmountOut() external view returns (uint256 _amount) {
        return _swapContext.amountOut;
    }

    /// @notice Get the amount of tokens swapped in the last operation
    /// @return _amount The amount of source tokens swapped
    function getLastAmountIn() external view returns (uint256 _amount) {
        return _swapContext.amountIn;
    }
}
