// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Local Interfaces
import {
    I1InchAggregationRouterV6,
    IAggregationExecutor
} from "metawallet/src/interfaces/I1InchAggregationRouterV6.sol";
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { IHookResult } from "metawallet/src/interfaces/IHookResult.sol";

// External Libraries
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

// Local Errors
import {
    HOOKONEINCH_INACTIVE_CONTEXT,
    HOOKONEINCH_INSUFFICIENT_OUTPUT,
    HOOKONEINCH_INVALID_FLAGS,
    HOOKONEINCH_INVALID_HOOK_DATA,
    HOOKONEINCH_INVALID_ROUTER,
    HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND,
    HOOKONEINCH_RESIDUAL_SOURCE_TOKENS,
    HOOKONEINCH_ROUTER_NOT_ALLOWED
} from "metawallet/src/errors/Errors.sol";

/// @title OneInchSwapHook
/// @notice Hook for performing token swaps via 1inch Aggregation Router
/// @dev This hook performs the following operations:
///      1. Approves the 1inch router to spend the input token
///      2. Executes the swap via the 1inch router using pre-built calldata
///      3. Validates minimum output amount (slippage protection)
///      Stores execution context that can be read by subsequent hooks in the chain
///      Supports dynamic amounts by reading from previous hook's output
contract OneInchSwapHook is IHook, IHookResult, Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /* ///////////////////////////////////////////////////////////////
                              EVENTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a router's whitelist status changes
    /// @param router The router address
    /// @param allowed Whether the router is now allowed
    event RouterAllowedUpdated(address indexed router, bool allowed);

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

    /// @notice Tracks whether the hook is currently executing
    bool private _executionContext;

    /// @notice Stores swap context data for chaining
    SwapContext private _swapContext;

    /// @notice Temporary storage for dynamic swap execution
    address private _tempRouter;
    uint256 private _tempValue;
    bytes private _tempSwapCalldata;

    /// @notice Pre-action balance snapshot for delta computation
    uint256 private _preSwapDstBalance;

    /// @notice Whitelist of allowed router addresses
    mapping(address => bool) private _allowedRouters;

    /* ///////////////////////////////////////////////////////////////
                         HOOK DATA STRUCTURE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Data structure for 1inch swap operation
    /// @param router The 1inch aggregation router address (must be allow-listed)
    /// @param amountIn Exact source amount, or USE_PREVIOUS_HOOK_OUTPUT to read from chained hook
    /// @param minAmountOut Hook-level slippage gate (0 to skip)
    /// @param value ETH to forward to the router (non-zero only for native-ETH source)
    /// @param data Opaque DEX-path payload passed through to the router executor
    /// @param executor SwapDescription.executor — aggregation executor for the swap
    /// @param srcToken SwapDescription.srcToken — token being swapped from
    /// @param dstToken SwapDescription.dstToken — token being swapped to
    /// @param srcReceiver SwapDescription.srcReceiver — where the executor pulls src from
    /// @param receiver SwapDescription.dstReceiver — final receiver of dst tokens
    /// @param routerMinReturn SwapDescription.minReturnAmount — router-level slippage gate
    /// @param flags SwapDescription.flags — MUST be 0 (allow-list approach)
    struct SwapData {
        address router;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 value;
        bytes data;
        address executor;
        address srcToken;
        address dstToken;
        address srcReceiver;
        address receiver;
        uint256 routerMinReturn;
        uint256 flags;
    }

    /// @notice Deploys the hook and sets the initial owner
    /// @param _owner The address that will own this hook
    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /* ///////////////////////////////////////////////////////////////
                              MODIFIERS
    ///////////////////////////////////////////////////////////////*/

    /// @dev Every state-mutating entry point other than init/finalize must run inside
    ///      an active MetaWallet chain. Without this, EXECUTOR_ROLE could call
    ///      resolveDynamicAmount/approveForSwap/executeSwap directly via MetaWallet's
    ///      generic `execute` dispatch and drain the hook's balance even with the
    ///      router allow-list, because 1inch honors the attacker-chosen dstReceiver.
    modifier onlyInsideChain() {
        _onlyInsideChain();
        _;
    }

    /// @dev Wrapped modifier body — see forge lint `unwrapped-modifier-logic`.
    ///      `view` because the modifier is also applied to view functions (e.g.
    ///      validateMinOutput); Solidity rejects a non-view call from a view fn.
    function _onlyInsideChain() internal view {
        require(_executionContext, HOOKONEINCH_INACTIVE_CONTEXT);
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
        SwapData memory _swapData = abi.decode(_data, (SwapData));

        // Shared invariants
        require(_swapData.router != address(0), HOOKONEINCH_INVALID_ROUTER);
        require(_allowedRouters[_swapData.router], HOOKONEINCH_ROUTER_NOT_ALLOWED);
        require(_swapData.srcToken != address(0), HOOKONEINCH_INVALID_HOOK_DATA);
        require(_swapData.dstToken != address(0), HOOKONEINCH_INVALID_HOOK_DATA);
        require(_swapData.receiver != address(0), HOOKONEINCH_INVALID_HOOK_DATA);
        require(_swapData.flags == 0, HOOKONEINCH_INVALID_FLAGS);

        bool _useDynamicAmount = _swapData.amountIn == USE_PREVIOUS_HOOK_OUTPUT;
        bool _isNativeEth = _swapData.srcToken == NATIVE_ETH;

        if (_useDynamicAmount) {
            require(_previousHook != address(0), HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND);

            // [resolveDynamicAmount, (approve if not ETH), swap, (resetApproval if not ETH), (optional) validate]
            uint256 _baseExecCount = _isNativeEth ? 2 : 4;
            uint256 _execCount = _swapData.minAmountOut > 0 ? _baseExecCount + 1 : _baseExecCount;
            _executions = new Execution[](_execCount);

            uint256 _idx = 0;

            _executions[_idx++] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(this.resolveDynamicAmount.selector, _previousHook, _swapData)
            });

            if (!_isNativeEth) {
                _executions[_idx++] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.approveForSwap.selector, _swapData.router)
                });
            }

            _executions[_idx++] = Execution({
                target: address(this),
                value: _isNativeEth ? _swapData.value : 0,
                callData: abi.encodeWithSelector(this.executeSwap.selector, _swapData.receiver)
            });

            // Reset residual approval after swap
            if (!_isNativeEth) {
                _executions[_idx++] = Execution({
                    target: address(this), value: 0, callData: abi.encodeWithSelector(this.resetSwapApproval.selector)
                });
            }

            if (_swapData.minAmountOut > 0) {
                _executions[_idx] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinOutput.selector, _swapData.minAmountOut)
                });
            }
        } else {
            require(_swapData.amountIn > 0, HOOKONEINCH_INVALID_HOOK_DATA);

            bytes memory _swapCalldata = _buildSwapCalldata(_swapData.amountIn, _swapData);

            // [approve (if not ETH), snapshot, swap, resetApproval (if not ETH), storeContext, (optional) validate]
            uint256 _baseExecCount = _isNativeEth ? 3 : 5;
            uint256 _execCount = _swapData.minAmountOut > 0 ? _baseExecCount + 1 : _baseExecCount;
            _executions = new Execution[](_execCount);

            uint256 _idx = 0;

            if (!_isNativeEth) {
                _executions[_idx++] = Execution({
                    target: _swapData.srcToken,
                    value: 0,
                    callData: abi.encodeWithSelector(IERC20.approve.selector, _swapData.router, _swapData.amountIn)
                });
            }

            _executions[_idx++] = Execution({
                target: address(this),
                value: 0,
                callData: abi.encodeWithSelector(
                    this.snapshotDstBalance.selector, _swapData.dstToken, _swapData.receiver
                )
            });

            _executions[_idx++] =
                Execution({ target: _swapData.router, value: _swapData.value, callData: _swapCalldata });

            // Clear residual approval after swap
            if (!_isNativeEth) {
                _executions[_idx++] = Execution({
                    target: _swapData.srcToken,
                    value: 0,
                    callData: abi.encodeWithSelector(IERC20.approve.selector, _swapData.router, uint256(0))
                });
            }

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

            if (_swapData.minAmountOut > 0) {
                _executions[_idx] = Execution({
                    target: address(this),
                    value: 0,
                    callData: abi.encodeWithSelector(this.validateMinOutput.selector, _swapData.minAmountOut)
                });
            }
        }
    }

    /// @inheritdoc IHook
    /// @dev Idempotent cleanup of temp/context storage: if a prior chain aborted without
    ///      reaching finalizeHookContext, stale values from that chain must not leak into
    ///      this one. Safe to re-run — every field is writer-owned by the chain itself.
    function initializeHookContext() external override onlyOwner {
        _executionContext = true;

        delete _swapContext;
        delete _tempRouter;
        delete _tempValue;
        delete _tempSwapCalldata;
        delete _preSwapDstBalance;
    }

    /// @inheritdoc IHook
    function finalizeHookContext() external override onlyOwner {
        _executionContext = false;

        delete _swapContext;
        delete _tempRouter;
        delete _tempValue;
        delete _tempSwapCalldata;
        delete _preSwapDstBalance;
    }

    /* ///////////////////////////////////////////////////////////////
                         IHOOKRESULT IMPLEMENTATION
    ///////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHookResult
    function getOutputAmount() external view override returns (uint256 _outputAmount) {
        return _swapContext.amountOut;
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT RESOLUTION
    ///////////////////////////////////////////////////////////////*/

    /// @notice Resolve the dynamic amount from the previous hook and build swap calldata
    /// @dev Called during execution. Duplicates allow-list + flags invariants from
    ///      buildExecutions because this entry point receives a fresh SwapData (it
    ///      is not inherently trusted to match the one buildExecutions validated).
    /// @param _previousHook The address of the previous hook
    /// @param _swapData The swap data (amountIn is ignored; resolved from previousHook)
    function resolveDynamicAmount(
        address _previousHook,
        SwapData calldata _swapData
    )
        external
        onlyOwner
        onlyInsideChain
    {
        require(_allowedRouters[_swapData.router], HOOKONEINCH_ROUTER_NOT_ALLOWED);
        require(_swapData.flags == 0, HOOKONEINCH_INVALID_FLAGS);

        uint256 _amount = IHookResult(_previousHook).getOutputAmount();
        require(_amount > 0, HOOKONEINCH_INVALID_HOOK_DATA);

        _swapContext = SwapContext({
            srcToken: _swapData.srcToken,
            dstToken: _swapData.dstToken,
            amountIn: _amount,
            amountOut: 0,
            receiver: address(0),
            timestamp: block.timestamp
        });

        _tempRouter = _swapData.router;
        _tempValue = _swapData.value;
        _tempSwapCalldata = _buildSwapCalldata(_amount, _swapData);
    }

    /* ///////////////////////////////////////////////////////////////
                         CALLDATA CONSTRUCTION
    ///////////////////////////////////////////////////////////////*/

    /// @dev Build 1inch V6 swap calldata from typed fields. Centralised so both the
    ///      static path (buildExecutions) and the dynamic path (resolveDynamicAmount)
    ///      emit byte-identical encoding. No caller-supplied offsets — the amount
    ///      always lands in desc.amount because we build the struct ourselves.
    ///      Casts: SwapData uses `address` throughout (simpler to hand-construct in
    ///      tests and off-chain encoders); the verified V6 SwapDescription uses
    ///      IERC20/address payable. The casts here are ABI-identity (same 20-byte
    ///      value, same encoding slot) — they exist purely for Solidity type checking.
    function _buildSwapCalldata(
        uint256 _amount,
        SwapData memory _swapData
    )
        internal
        pure
        returns (bytes memory _callData)
    {
        I1InchAggregationRouterV6.SwapDescription memory _desc = I1InchAggregationRouterV6.SwapDescription({
            srcToken: IERC20(_swapData.srcToken),
            dstToken: IERC20(_swapData.dstToken),
            srcReceiver: payable(_swapData.srcReceiver),
            dstReceiver: payable(_swapData.receiver),
            amount: _amount,
            minReturnAmount: _swapData.routerMinReturn,
            flags: _swapData.flags
        });

        _callData = abi.encodeCall(
            I1InchAggregationRouterV6.swap, (IAggregationExecutor(_swapData.executor), _desc, _swapData.data)
        );
    }

    /// @notice Snapshot the receiver's destination token balance before a static swap
    /// @dev Called before the router swap execution to enable delta computation
    /// @param _token The destination token to snapshot
    /// @param _account The account whose balance to snapshot
    function snapshotDstBalance(address _token, address _account) external onlyOwner onlyInsideChain {
        _preSwapDstBalance = IERC20(_token).balanceOf(_account);
    }

    /// @notice Approve the router to spend source tokens (for dynamic amount flow)
    /// @param _router The 1inch router address
    function approveForSwap(address _router) external onlyOwner onlyInsideChain {
        require(_allowedRouters[_router], HOOKONEINCH_ROUTER_NOT_ALLOWED);
        SwapContext memory _ctx = _swapContext;
        if (_ctx.srcToken == NATIVE_ETH) return;
        (_ctx.srcToken).safeApproveWithRetry(_router, _ctx.amountIn);
    }

    /// @notice Reset the router approval to 0 after a swap (for dynamic amount flow)
    /// @dev Clears any residual approval from the hook to the router
    function resetSwapApproval() external onlyOwner onlyInsideChain {
        address _srcToken = _swapContext.srcToken;
        if (_srcToken != NATIVE_ETH) {
            _srcToken.safeApprove(_tempRouter, 0);
        }
    }

    /// @notice Execute the swap (for dynamic amount flow)
    /// @dev This function needs the router and swap calldata to be stored first via resolveDynamicAmount
    /// @param _receiver The address to receive the swapped tokens
    function executeSwap(address _receiver) external payable onlyOwner onlyInsideChain nonReentrant {
        SwapContext storage _ctx = _swapContext;

        // Snapshot destination token balance before swap for delta computation
        uint256 _balBefore = IERC20(_ctx.dstToken).balanceOf(_receiver);

        // Load router address, value and calldata from storage
        address _router = _tempRouter;
        require(_allowedRouters[_router], HOOKONEINCH_ROUTER_NOT_ALLOWED);
        uint256 _value = _tempValue;
        bytes memory _calldata = _tempSwapCalldata;

        // Snapshot source token balance before swap
        address _srcToken = _ctx.srcToken;
        uint256 _srcBalBefore = _srcToken != NATIVE_ETH ? IERC20(_srcToken).balanceOf(address(this)) : 0;

        // Execute the swap - this will pull tokens from this hook via transferFrom.
        // On failure, bubble up the router's revert data so typed errors such as
        // ReturnAmountIsNotEnough, ZeroMinReturn, or InvalidMsgValue are diagnosable
        // by the caller instead of being flattened into a single generic string.
        (bool _success, bytes memory _returnData) = _router.call{ value: _value }(_calldata);
        if (!_success) {
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                revert(add(_returnData, 0x20), mload(_returnData))
            }
        }

        // Revert if source tokens remain stranded (calldata amount < dynamic amount)
        if (_srcToken != NATIVE_ETH) {
            uint256 _srcBalAfter = IERC20(_srcToken).balanceOf(address(this));
            require(_srcBalAfter <= _srcBalBefore - _ctx.amountIn, HOOKONEINCH_RESIDUAL_SOURCE_TOKENS);
        }

        _ctx.amountOut = IERC20(_ctx.dstToken).balanceOf(_receiver) - _balBefore;
        _ctx.receiver = _receiver;
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Store swap context after execution (for static amount flow)
    /// @dev Uses balance delta (current - snapshot) to correctly measure output received
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
        onlyInsideChain
    {
        uint256 _amountOut = IERC20(_dstToken).balanceOf(_receiver) - _preSwapDstBalance;

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

    /// @notice Validates that the swap produced at least the minimum expected output
    /// @param _minAmountOut The minimum expected output amount
    function validateMinOutput(uint256 _minAmountOut) external view onlyOwner onlyInsideChain {
        require(_swapContext.amountOut >= _minAmountOut, HOOKONEINCH_INSUFFICIENT_OUTPUT);
    }

    /* ///////////////////////////////////////////////////////////////
                         ROUTER MANAGEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Set whether a router address is allowed for swaps
    /// @param _router The router address
    /// @param _allowed Whether the router is allowed
    function setRouterAllowed(address _router, bool _allowed) external onlyOwner {
        require(_router != address(0), HOOKONEINCH_INVALID_ROUTER);
        _allowedRouters[_router] = _allowed;
        emit RouterAllowedUpdated(_router, _allowed);
    }

    /// @notice Check if a router address is allowed
    /// @param _router The router address to check
    /// @return _allowed Whether the router is allowed
    function isRouterAllowed(address _router) external view returns (bool _allowed) {
        return _allowedRouters[_router];
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Check if the hook has an active execution context
    /// @return _hasContext Whether there is an active execution context
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
