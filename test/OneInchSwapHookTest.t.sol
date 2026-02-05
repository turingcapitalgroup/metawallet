// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Test Base
import { console } from "forge-std/console.sol";
import { BaseTest } from "metawallet/test/base/BaseTest.t.sol";

// External Libraries
import { ERC1967Factory } from "solady/utils/ERC1967Factory.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Local Contracts
import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { USDC_MAINNET, _1_USDC } from "metawallet/src/helpers/AddressBook.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

// Local Interfaces
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IHookExecution } from "metawallet/src/interfaces/IHookExecution.sol";
import { IMetaWallet } from "metawallet/src/interfaces/IMetaWallet.sol";

// Mock Contracts
import { MockOneInchRouter } from "metawallet/test/helpers/mocks/MockOneInchRouter.sol";
import { MockRegistry } from "metawallet/test/helpers/mocks/MockRegistry.sol";

// Errors
import "metawallet/src/errors/Errors.sol" as Errors;

// Access Control
import { Ownable } from "solady/auth/Ownable.sol";

// 1inch interfaces
interface IAggregationExecutor {
    function execute(address msgSender) external payable returns (uint256);
}

interface I1InchAggregationRouterV6 {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function swap(
        IAggregationExecutor executor,
        SwapDescription calldata desc,
        bytes calldata data
    )
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount);
}

contract OneInchSwapHookTest is BaseTest {
    using SafeTransferLib for address;

    /* ///////////////////////////////////////////////////////////////
                              CONTRACTS
    ///////////////////////////////////////////////////////////////*/

    IMetaWallet public metaWallet;
    ERC1967Factory public proxyFactory;
    OneInchSwapHook public swapHook;
    ERC4626ApproveAndDepositHook public depositHook;
    ERC4626RedeemHook public redeemHook;
    MockRegistry public registry;
    MockOneInchRouter public oneInchRouter;

    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    uint256 public constant INITIAL_BALANCE = 10_000 * _1_USDC; // 10,000 USDC
    uint256 public constant SWAP_AMOUNT = 1000 * _1_USDC; // 1,000 USDC

    bytes32 public constant SWAP_HOOK_ID = keccak256("hook.oneinch.swap");
    bytes32 public constant DEPOSIT_HOOK_ID = keccak256("hook.erc4626.deposit");
    bytes32 public constant REDEEM_HOOK_ID = keccak256("hook.erc4626.redeem");

    // Using real mainnet token addresses
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant VAULT_A = 0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204;

    // Real 1inch Aggregation Router V6 on mainnet
    address public constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Native ETH sentinel address used by 1inch
    address public constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /* ///////////////////////////////////////////////////////////////
                              SETUP
    ///////////////////////////////////////////////////////////////*/

    function setUp() public {
        _setUp("MAINNET", 23_989_931);
        vm.stopPrank(); // Stop the automatic prank from BaseTest

        // Deploy registry
        registry = new MockRegistry();

        // Deploy mock 1inch router
        oneInchRouter = new MockOneInchRouter();

        // Deploy proxy factory and MetaWallet implementation
        proxyFactory = new ERC1967Factory();
        MetaWallet _metaWalletImplementation = new MetaWallet();

        // Initialize MetaWallet proxy
        bytes memory _initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, address(registry), "metawallet.hooks.1.0"
        );
        address _metaWalletProxy =
            proxyFactory.deployAndCall(address(_metaWalletImplementation), users.admin, _initData);

        // Grant admin and executor roles
        vm.prank(users.owner);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.admin, 1); // ADMIN_ROLE
        vm.prank(users.owner);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.owner, 2); // EXECUTOR_ROLE

        // Deploy and add VaultModule
        VaultModule _vault = new VaultModule();
        bytes4[] memory _vaultSelectors = _vault.selectors();

        vm.startPrank(users.admin);
        MetaWallet(payable(_metaWalletProxy)).addFunctions(_vaultSelectors, address(_vault), false);
        VaultModule(_metaWalletProxy).initializeVault(address(USDC_MAINNET), "Meta USDC", "mUSDC");
        vm.stopPrank();

        metaWallet = IMetaWallet(_metaWalletProxy);

        // Deploy hooks
        swapHook = new OneInchSwapHook(address(metaWallet));
        depositHook = new ERC4626ApproveAndDepositHook(address(metaWallet));
        redeemHook = new ERC4626RedeemHook(address(metaWallet));

        // Install hooks in the wallet
        vm.startPrank(users.admin);
        MetaWallet(payable(address(metaWallet))).installHook(SWAP_HOOK_ID, address(swapHook));
        MetaWallet(payable(address(metaWallet))).installHook(DEPOSIT_HOOK_ID, address(depositHook));
        MetaWallet(payable(address(metaWallet))).installHook(REDEEM_HOOK_ID, address(redeemHook));
        vm.stopPrank();

        // Whitelist routers in swap hook
        vm.startPrank(address(metaWallet));
        swapHook.setRouterAllowed(address(oneInchRouter), true);
        swapHook.setRouterAllowed(ONEINCH_ROUTER, true);
        vm.stopPrank();

        // Whitelist contracts in registry
        registry.whitelistTarget(address(swapHook));
        registry.whitelistTarget(address(depositHook));
        registry.whitelistTarget(address(redeemHook));
        registry.whitelistTarget(address(USDC_MAINNET));
        registry.whitelistTarget(address(oneInchRouter));
        registry.whitelistTarget(address(ONEINCH_ROUTER));
        registry.whitelistTarget(address(WETH));
        registry.whitelistTarget(address(VAULT_A));

        // Setup initial balances for the wallet
        deal(USDC_MAINNET, address(metaWallet), INITIAL_BALANCE);
        deal(address(metaWallet), 1 ether); // Fund with ETH for native swaps

        // Setup WETH balance for the mock router (to simulate swap output)
        // Need large amount because mock router does: amount * exchangeRate * decimalAdjustment / 1e18
        // For USDC->WETH: 1000e6 * 1e18 * 1e12 / 1e18 = 1000e18, so need enough for all tests
        deal(WETH, address(oneInchRouter), 10_000_000 ether);

        // Setup USDC balance for the mock router (for reverse swaps)
        deal(USDC_MAINNET, address(oneInchRouter), INITIAL_BALANCE * 10);

        // Label addresses for better trace output
        vm.label(address(swapHook), "SwapHook");
        vm.label(address(depositHook), "DepositHook");
        vm.label(address(redeemHook), "RedeemHook");
        vm.label(address(metaWallet), "MetaWallet");
        vm.label(address(registry), "Registry");
        vm.label(address(oneInchRouter), "OneInchRouter");
        vm.label(address(USDC_MAINNET), "USDC");
        vm.label(address(WETH), "WETH");

        // Log addresses for 1inch API
        console.log("=== 1inch API Parameters ===");
        console.log("MetaWallet (from):", address(metaWallet));
        console.log("EOA Owner (origin):", users.owner);
    }

    /* ///////////////////////////////////////////////////////////////
                         STATIC AMOUNT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_SingleSwapHook_StaticAmount() public {
        // Build the 1inch swap calldata using the mock router's expected format
        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            USDC_MAINNET,
            WETH,
            SWAP_AMOUNT,
            0, // minReturn
            address(metaWallet)
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0, // No ETH value for token->token swap
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _usdcBalanceBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _wethBalanceBefore = WETH.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _usdcBalanceAfter = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _wethBalanceAfter = WETH.balanceOf(address(metaWallet));

        // Verify USDC was spent
        assertEq(_usdcBalanceBefore - _usdcBalanceAfter, SWAP_AMOUNT, "USDC spent mismatch");

        // Verify WETH was received
        assertGt(_wethBalanceAfter, _wethBalanceBefore, "WETH not received");
    }

    function test_SingleSwapHook_StaticAmount_WithETHValue() public {
        uint256 _swapAmount = 0.01 ether;

        // Set exchange rate for ETH -> WETH (same decimals, 1:1 rate)
        oneInchRouter.setExchangeRate(1e18);
        oneInchRouter.setDecimalAdjustment(1); // Same decimals (18 -> 18)

        // Build the swap calldata using the mock router
        // The mock router will handle the swap and send WETH to the receiver
        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            NATIVE_ETH, // srcToken is native ETH
            WETH,
            _swapAmount,
            0, // minReturn
            address(metaWallet)
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: NATIVE_ETH,
            dstToken: WETH,
            amountIn: _swapAmount,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: _swapAmount, // ETH value for native swap
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _ethBalanceBefore = address(metaWallet).balance;
        uint256 _wethBalanceBefore = WETH.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _ethBalanceAfter = address(metaWallet).balance;
        uint256 _wethBalanceAfter = WETH.balanceOf(address(metaWallet));

        // Verify ETH was spent
        assertEq(_ethBalanceBefore - _ethBalanceAfter, _swapAmount, "ETH spent mismatch");

        // Verify WETH was received
        assertGt(_wethBalanceAfter, _wethBalanceBefore, "WETH not received");
    }

    function test_SingleSwapHook_WithSlippageProtection() public {
        // Set a known exchange rate on the mock router
        oneInchRouter.setExchangeRate(0.5e18); // 0.5 WETH per USDC (scaled)
        oneInchRouter.setDecimalAdjustment(1e12); // USDC 6 decimals -> WETH 18 decimals

        // Expected output: 1000 * 0.5 * 1e12 = 500e18 / 1e18 = 500e12 wei WETH
        // With decimal adjustment: 1000e6 * 0.5e18 * 1e12 / 1e18 = 500e18

        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            USDC_MAINNET,
            WETH,
            SWAP_AMOUNT,
            400e18, // minReturn - expect at least 400 WETH (in wei)
            address(metaWallet)
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 400e18, // Slippage protection
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _wethBalance = WETH.balanceOf(address(metaWallet));
        assertGe(_wethBalance, 400e18, "Slippage protection failed");
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_SwapAfterDeposit_DynamicAmount() public {
        // First, deposit USDC to vault and get shares
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: SWAP_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        // Then swap the shares (output of deposit) - but we need to swap USDC
        // For this test, let's do: Deposit -> Redeem -> Swap the redeemed USDC
        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(), // Dynamic - use deposit output
            receiver: address(swapHook), // Send USDC to swap hook for next step
            owner: address(metaWallet),
            minAssets: 0
        });

        // Now swap the USDC output from redeem
        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            USDC_MAINNET,
            WETH,
            0, // Amount will be determined dynamically
            0, // minReturn
            address(metaWallet)
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(), // Dynamic!
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _wethBefore = WETH.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _wethAfter = WETH.balanceOf(address(metaWallet));

        // Verify WETH was received from the swap
        assertGt(_wethAfter, _wethBefore, "WETH not received after swap chain");
    }

    function test_SwapThenDeposit_DynamicAmount() public {
        // First swap USDC to get different token, then deposit that token
        // For simplicity, we'll swap USDC -> USDC (same token) to test the flow

        // Set 1:1 rate for same-token swap simulation
        oneInchRouter.setExchangeRate(1e18);
        oneInchRouter.setDecimalAdjustment(1); // Same decimals

        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            USDC_MAINNET,
            USDC_MAINNET, // Swap to same token for test simplicity
            SWAP_AMOUNT,
            0,
            address(depositHook) // Send output to deposit hook
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: USDC_MAINNET,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(depositHook),
            value: 0,
            swapCalldata: _swapCalldata
        });

        // Deposit the swap output into vault
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A),
                assets: depositHook.USE_PREVIOUS_HOOK_OUTPUT(), // Dynamic!
                receiver: address(metaWallet),
                minShares: 0
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](2);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        uint256 _sharesBefore = VAULT_A.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _sharesAfter = VAULT_A.balanceOf(address(metaWallet));

        // Verify shares were received from deposit
        assertGt(_sharesAfter, _sharesBefore, "Vault shares not received after swap->deposit chain");
    }

    /* ///////////////////////////////////////////////////////////////
                         ERROR CASE TESTS
    ///////////////////////////////////////////////////////////////*/

    function testRevert_DynamicAmount_NoPreviousHook() public {
        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, 0, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(), // Dynamic but no previous hook!
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_SlippageProtection_InsufficientOutput() public {
        oneInchRouter.setExchangeRate(0.1e18); // Very low rate
        oneInchRouter.setDecimalAdjustment(1e12);

        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            USDC_MAINNET,
            WETH,
            SWAP_AMOUNT,
            0, // No minimum in router call - validation happens in hook
            address(metaWallet)
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 1000e18, // Expect way more than we'll get
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INSUFFICIENT_OUTPUT));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_InvalidRouter() public {
        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, SWAP_AMOUNT, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(0), // Invalid!
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_ROUTER));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_InvalidSrcToken() public {
        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, SWAP_AMOUNT, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: address(0), // Invalid!
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_InvalidDstToken() public {
        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, SWAP_AMOUNT, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: address(0), // Invalid!
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_InvalidReceiver() public {
        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, SWAP_AMOUNT, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(0), // Invalid!
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_EmptySwapCalldata() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: "" // Empty!
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_ZeroAmountStatic() public {
        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            USDC_MAINNET,
            WETH,
            0, // Zero amount
            0,
            address(metaWallet)
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: 0, // Zero - invalid for static
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_UnauthorizedExecution() public {
        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, SWAP_AMOUNT, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        // Alice doesn't have EXECUTOR_ROLE
        vm.prank(users.alice);
        vm.expectRevert("Unauthorized()");
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /* ///////////////////////////////////////////////////////////////
                         VIEW FUNCTION TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_UsePreviousHookOutputConstant() public view {
        assertEq(swapHook.USE_PREVIOUS_HOOK_OUTPUT(), type(uint256).max);
    }

    /* ///////////////////////////////////////////////////////////////
                         CONTEXT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_SwapContextStoredCorrectly() public {
        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, SWAP_AMOUNT, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        // After execution, context should be cleared
        OneInchSwapHook.SwapContext memory _ctx = swapHook.getSwapContext();

        // Context is cleaned up after finalization
        assertEq(_ctx.srcToken, address(0));
        assertEq(_ctx.dstToken, address(0));
    }

    /* ///////////////////////////////////////////////////////////////
                         COMPLEX CHAIN TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_ComplexChain_DepositRedeemSwap() public {
        // Chain: Deposit USDC -> Redeem shares -> Swap USDC to WETH
        // This tests full hook chaining capability

        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: SWAP_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(),
            receiver: address(swapHook),
            owner: address(metaWallet),
            minAssets: 0
        });

        bytes memory _swapCalldata = oneInchRouter.encodeSwapCalldata(
            USDC_MAINNET,
            WETH,
            0, // Dynamic
            0,
            address(metaWallet)
        );

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(),
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _usdcBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _wethBefore = WETH.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _usdcAfter = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _wethAfter = WETH.balanceOf(address(metaWallet));

        // USDC should have decreased (used in deposit, some returned in redeem, then swapped)
        assertLt(_usdcAfter, _usdcBefore, "USDC balance should decrease");

        // WETH should have increased (from swap)
        assertGt(_wethAfter, _wethBefore, "WETH balance should increase");
    }

    /* ///////////////////////////////////////////////////////////////
                    DELTA TRACKING & SLIPPAGE TESTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Tests swap delta tracking reverts with pre-existing dstTokens when
    ///         actual output is below minAmountOut
    function test_SwapDeltaTracking_RevertsWithPreExistingDstTokens() public {
        deal(USDC_MAINNET, address(metaWallet), 100_000 * _1_USDC);

        uint256 _preExistingWeth = 200 ether;
        deal(WETH, address(metaWallet), _preExistingWeth);

        oneInchRouter.setExchangeRate(5e16);

        uint256 _swapAmount = 1000 * _1_USDC;
        uint256 _minOutput = 100 ether;

        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, _swapAmount, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: _swapAmount,
            minAmountOut: _minOutput,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert();
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /// @notice Tests swap static amount produces correct delta-based output
    function test_SwapStatic_DeltaBasedOutput() public {
        deal(USDC_MAINNET, address(metaWallet), 100_000 * _1_USDC);

        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, 1000 * _1_USDC, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: 1000 * _1_USDC,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _wethBefore = IERC20(WETH).balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _wethAfter = IERC20(WETH).balanceOf(address(metaWallet));
        assertGt(_wethAfter, _wethBefore, "Should have received WETH from swap");
    }

    /// @notice Tests swap slippage correctly reverts when pre-existing balance masks
    ///         insufficient actual output
    function test_SwapSlippage_RevertsWithPreExistingBalance() public {
        deal(USDC_MAINNET, address(metaWallet), 100_000 * _1_USDC);

        deal(WETH, address(metaWallet), 200 ether);

        oneInchRouter.setExchangeRate(5e16);

        uint256 _swapAmount = 1000 * _1_USDC;
        uint256 _minOutput = 100 ether;

        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, _swapAmount, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: _swapAmount,
            minAmountOut: _minOutput,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert();
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /// @notice Tests swap slippage reverts with very low exchange rate
    function testRevert_SwapSlippage_InsufficientOutput_LowRate() public {
        deal(USDC_MAINNET, address(metaWallet), 100_000 * _1_USDC);

        oneInchRouter.setExchangeRate(1e14);

        uint256 _swapAmount = 1000 * _1_USDC;
        uint256 _minOutput = 900 ether;

        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, _swapAmount, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: _swapAmount,
            minAmountOut: _minOutput,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert();
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /// @notice Tests context cleanup after both deposit and swap executions
    function test_ContextCleanup_AfterSwapAndDepositExecution() public {
        deal(USDC_MAINNET, address(metaWallet), 100_000 * _1_USDC);

        _executeDeposit(address(VAULT_A), 5000 * _1_USDC, 0);

        assertFalse(depositHook.hasActiveContext(), "Deposit hook context should be cleaned");
        assertEq(depositHook.getOutputAmount(), 0, "Deposit output should be 0 after cleanup");

        _executeSwap(USDC_MAINNET, WETH, 1000 * _1_USDC, 0);

        assertFalse(swapHook.hasActiveContext(), "Swap hook context should be cleaned");
        assertEq(swapHook.getOutputAmount(), 0, "Swap output should be 0 after cleanup");
    }

    /* ///////////////////////////////////////////////////////////////
                    ROUTER WHITELIST TESTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Attempting a swap with an unwhitelisted router should revert with H1I5
    function testRevert_SwapWithUnwhitelistedRouter() public {
        address _randomRouter = address(0xDEAD);

        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(USDC_MAINNET, WETH, SWAP_AMOUNT, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: _randomRouter,
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_ROUTER_NOT_ALLOWED));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /// @notice Whitelist a router, verify it's allowed, remove it, verify it's not allowed
    function test_SetRouterAllowed_WhitelistAndRemove() public {
        address _newRouter = address(0xBEEF);

        // Initially not allowed
        assertFalse(swapHook.isRouterAllowed(_newRouter), "Router should not be allowed initially");

        // Whitelist the router (owner is metaWallet)
        vm.prank(address(metaWallet));
        swapHook.setRouterAllowed(_newRouter, true);

        // Now it should be allowed
        assertTrue(swapHook.isRouterAllowed(_newRouter), "Router should be allowed after whitelisting");

        // Remove from whitelist
        vm.prank(address(metaWallet));
        swapHook.setRouterAllowed(_newRouter, false);

        // Should no longer be allowed
        assertFalse(swapHook.isRouterAllowed(_newRouter), "Router should not be allowed after removal");
    }

    /// @notice Non-owner calls setRouterAllowed, should revert with Ownable.Unauthorized
    function testRevert_SetRouterAllowed_Unauthorized() public {
        address _newRouter = address(0xBEEF);

        vm.prank(users.alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        swapHook.setRouterAllowed(_newRouter, true);
    }

    /// @notice Setting zero address as router should revert with H1I4 (HOOKONEINCH_INVALID_ROUTER)
    function testRevert_SetRouterAllowed_ZeroAddress() public {
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_ROUTER));
        swapHook.setRouterAllowed(address(0), true);
    }

    /* ///////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Build 1inch swap calldata using the generic swap function
    function _build1InchSwapCalldata(
        address _srcToken,
        address _dstToken,
        address _srcReceiver,
        address _dstReceiver,
        uint256 _amount,
        uint256 _minReturnAmount
    )
        internal
        pure
        returns (bytes memory)
    {
        I1InchAggregationRouterV6.SwapDescription memory desc = I1InchAggregationRouterV6.SwapDescription({
            srcToken: IERC20(_srcToken),
            dstToken: IERC20(_dstToken),
            srcReceiver: payable(_srcReceiver),
            dstReceiver: payable(_dstReceiver),
            amount: _amount,
            minReturnAmount: _minReturnAmount,
            flags: 0 // no partial fill
        });

        bytes memory swapData = abi.encode(
            address(0), // executor (not used for simple swaps)
            desc,
            bytes(""), // permit
            bytes("") // extra data
        );

        return abi.encodePacked(I1InchAggregationRouterV6.swap.selector, swapData);
    }

    /// @notice Helper to execute a deposit via hook execution
    function _executeDeposit(address _vault, uint256 _amount, uint256 _minShares) internal {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _data =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: _vault, assets: _amount, receiver: address(metaWallet), minShares: _minShares
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /// @notice Helper to execute a swap via hook execution
    function _executeSwap(address _srcToken, address _dstToken, uint256 _amount, uint256 _minOutput) internal {
        bytes memory _swapCalldata =
            oneInchRouter.encodeSwapCalldata(_srcToken, _dstToken, _amount, 0, address(metaWallet));

        OneInchSwapHook.SwapData memory _data = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            srcToken: _srcToken,
            dstToken: _dstToken,
            amountIn: _amount,
            minAmountOut: _minOutput,
            receiver: address(metaWallet),
            value: 0,
            swapCalldata: _swapCalldata
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }
}
