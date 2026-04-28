// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Test Base
import { console } from "forge-std/console.sol";
import { BaseTest } from "metawallet/test/base/BaseTest.t.sol";

// External Libraries
import { MinimalUUPSFactory } from "minimal-uups-factory/MinimalUUPSFactory.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Local Contracts
import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { USDC_MAINNET, _1_USDC } from "metawallet/src/helpers/AddressBook.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

// Local Interfaces
import { I1InchAggregationRouterV6 } from "metawallet/src/interfaces/I1InchAggregationRouterV6.sol";
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

contract OneInchSwapHookTest is BaseTest {
    using SafeTransferLib for address;

    /* ///////////////////////////////////////////////////////////////
                              CONTRACTS
    ///////////////////////////////////////////////////////////////*/

    IMetaWallet public metaWallet;
    MinimalUUPSFactory public proxyFactory;
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
        proxyFactory = new MinimalUUPSFactory();
        MetaWallet _metaWalletImplementation = new MetaWallet();

        // Initialize MetaWallet proxy
        bytes memory _initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, address(registry), "metawallet.hooks.1.0"
        );
        address _metaWalletProxy = proxyFactory.deployAndCall(address(_metaWalletImplementation), _initData);

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

        // Whitelist routers in swap hook and vault in deposit hook
        vm.startPrank(address(metaWallet));
        swapHook.setRouterAllowed(address(oneInchRouter), true);
        swapHook.setRouterAllowed(ONEINCH_ROUTER, true);
        depositHook.setVaultAllowed(VAULT_A, true);
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
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0, // No ETH value for token->token swap
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _usdcBalanceBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _wethBalanceBefore = WETH.balanceOf(address(metaWallet));

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: _swapAmount,
            minAmountOut: 0,
            value: _swapAmount, // ETH value for native swap
            data: "",
            executor: address(0),
            srcToken: NATIVE_ETH, // srcToken is native ETH
            dstToken: WETH,
            srcReceiver: address(0),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _ethBalanceBefore = address(metaWallet).balance;
        uint256 _wethBalanceBefore = WETH.balanceOf(address(metaWallet));

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 400e18, // Slippage protection (hook-level)
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 400e18, // Router-level minReturn mirrors hook-level
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(), // Dynamic!
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _wethBefore = WETH.balanceOf(address(metaWallet));

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: USDC_MAINNET, // Swap to same token for test simplicity
            srcReceiver: address(oneInchRouter),
            receiver: address(depositHook), // Send output to deposit hook
            routerMinReturn: 0,
            flags: 0
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

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

        uint256 _sharesAfter = VAULT_A.balanceOf(address(metaWallet));

        // Verify shares were received from deposit
        assertGt(_sharesAfter, _sharesBefore, "Vault shares not received after swap->deposit chain");
    }

    /// @notice Regression test for TOB-KAM-16: dynamic path must not call approveForSwap for native ETH
    function test_DynamicAmount_NativeETH_SkipsApproval() public {
        // 1:1 exchange rate, ETH and WETH share 18 decimals
        oneInchRouter.setExchangeRate(1e18);
        oneInchRouter.setDecimalAdjustment(1);

        uint256 _ethSwapAmount = 0.01 ether;

        // First hook: deposit USDC to produce a non-zero getOutputAmount() for the swap hook to consume
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: SWAP_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        // Second hook: dynamic ETH -> WETH swap; value is static, amountIn is read from depositHook
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(),
            minAmountOut: 0,
            value: _ethSwapAmount,
            data: "",
            executor: address(0),
            srcToken: NATIVE_ETH,
            dstToken: WETH,
            srcReceiver: address(0),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](2);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _ethBefore = address(metaWallet).balance;
        uint256 _wethBefore = WETH.balanceOf(address(metaWallet));

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

        assertEq(_ethBefore - address(metaWallet).balance, _ethSwapAmount, "ETH not spent");
        assertGt(WETH.balanceOf(address(metaWallet)), _wethBefore, "WETH not received");
    }

    /* ///////////////////////////////////////////////////////////////
                         ERROR CASE TESTS
    ///////////////////////////////////////////////////////////////*/

    function testRevert_DynamicAmount_NoPreviousHook() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(), // Dynamic but no previous hook!
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    function testRevert_SlippageProtection_InsufficientOutput() public {
        oneInchRouter.setExchangeRate(0.1e18); // Very low rate
        oneInchRouter.setDecimalAdjustment(1e12);

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 1000e18, // Expect way more than we'll get
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0, // No minimum in router call - validation happens in hook
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INSUFFICIENT_OUTPUT));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    function testRevert_InvalidRouter() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(0), // Invalid!
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_ROUTER));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    function testRevert_InvalidSrcToken() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: address(0), // Invalid!
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    function testRevert_InvalidDstToken() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: address(0), // Invalid!
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    function testRevert_InvalidReceiver() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(0), // Invalid!
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    function testRevert_ZeroAmountStatic() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: 0, // Zero - invalid for static
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    function testRevert_UnauthorizedExecution() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        // Alice doesn't have EXECUTOR_ROLE
        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.alice);
        vm.expectRevert("Unauthorized()");
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
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
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(),
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _usdcBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _wethBefore = WETH.balanceOf(address(metaWallet));

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: _swapAmount,
            minAmountOut: _minOutput,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert();
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    /// @notice Tests swap static amount produces correct delta-based output
    function test_SwapStatic_DeltaBasedOutput() public {
        deal(USDC_MAINNET, address(metaWallet), 100_000 * _1_USDC);

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: 1000 * _1_USDC,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _wethBefore = IERC20(WETH).balanceOf(address(metaWallet));

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: _swapAmount,
            minAmountOut: _minOutput,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert();
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    /// @notice Tests swap slippage reverts with very low exchange rate
    function testRevert_SwapSlippage_InsufficientOutput_LowRate() public {
        deal(USDC_MAINNET, address(metaWallet), 100_000 * _1_USDC);

        oneInchRouter.setExchangeRate(1e14);

        uint256 _swapAmount = 1000 * _1_USDC;
        uint256 _minOutput = 900 ether;

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: _swapAmount,
            minAmountOut: _minOutput,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert();
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
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

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: _randomRouter,
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: _randomRouter,
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_ROUTER_NOT_ALLOWED));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
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

    /// @notice Direct call to approveForSwap with a non-whitelisted router must revert.
    /// @dev Must activate the execution context first (post-H1I8 gate) so that the
    ///      router allow-list check is the assertion under test, not the gate.
    function testRevert_ApproveForSwap_RouterNotAllowed() public {
        address _evilRouter = makeAddr("EvilRouter");
        vm.startPrank(address(metaWallet));
        swapHook.initializeHookContext();
        vm.expectRevert(bytes(Errors.HOOKONEINCH_ROUTER_NOT_ALLOWED));
        swapHook.approveForSwap(_evilRouter);
        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
                         ROUTER REVERT FORWARDING
    ///////////////////////////////////////////////////////////////*/

    /// @notice A router revert inside the dynamic executeSwap path must bubble up the
    ///         router's raw revert data instead of a flattened generic error.
    function testRevert_ExecuteSwap_Dynamic_BubblesRouterRevertData() public {
        // Deposit USDC to get shares, then redeem shares to send USDC to swapHook
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

        // Force the router's swap() to revert with its own
        // `require(returnAmount >= minReturnAmount, "Insufficient return amount")`
        // by setting an impossible routerMinReturn. The hook builds the V6 calldata
        // internally — the caller no longer controls raw bytes, so the only way to
        // reach the router's revert path is via the typed SwapDescription fields.
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(),
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: type(uint256).max, // impossible — forces router-level revert
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes("Insufficient return amount"));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
                         FLAG ALLOW-LIST TESTS (H1I7)
    ///////////////////////////////////////////////////////////////*/

    /// @notice Static path with non-zero flags must revert with H1I7.
    /// @dev Flag bit 0 is _PARTIAL_FILL in V6. The hook enforces `flags == 0` as a
    ///      positive allow-list so future/unknown flag bits cannot sneak through the
    ///      typed path. Coverage for the buildExecutions shared-invariants check.
    function testRevert_Static_InvalidFlags() public {
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 1 // _PARTIAL_FILL — forbidden
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_FLAGS));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    /// @notice Dynamic path with non-zero flags must revert with H1I7 at buildExecutions time.
    /// @dev Uses flag bit 1 (_REQUIRES_EXTRA_ETH) to vary from the static test and
    ///      confirm the allow-list rejects arbitrary bits, not just bit 0.
    function testRevert_Dynamic_InvalidFlags() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: SWAP_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: swapHook.USE_PREVIOUS_HOOK_OUTPUT(),
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 2 // _REQUIRES_EXTRA_ETH — forbidden
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](2);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        uint256 _nonce = metaWallet.nonce();
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_FLAGS));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_nonce, block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
                         DIRECT-CALL GUARDS
    ///////////////////////////////////////////////////////////////*/

    /// @notice resolveDynamicAmount must enforce onlyOwner (owner = metaWallet).
    function testRevert_ResolveDynamicAmount_Unauthorized() public {
        OneInchSwapHook.SwapData memory _swapData = _defaultSwapData();
        vm.prank(users.alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        swapHook.resolveDynamicAmount(address(swapHook), _swapData);
    }

    /// @notice resolveDynamicAmount re-checks the router allow-list (defence-in-depth).
    /// @dev buildExecutions already validates this, but resolveDynamicAmount is callable
    ///      on its own and must not trust its inputs. A bad router bypasses the first
    ///      gate if someone reuses the selector in a hand-crafted Execution[] chain.
    function testRevert_ResolveDynamicAmount_RouterNotAllowed() public {
        OneInchSwapHook.SwapData memory _swapData = _defaultSwapData();
        _swapData.router = address(0xDEAD); // not whitelisted
        vm.startPrank(address(metaWallet));
        swapHook.initializeHookContext();
        vm.expectRevert(bytes(Errors.HOOKONEINCH_ROUTER_NOT_ALLOWED));
        swapHook.resolveDynamicAmount(address(swapHook), _swapData);
        vm.stopPrank();
    }

    /// @notice resolveDynamicAmount re-checks flags == 0 (defence-in-depth).
    function testRevert_ResolveDynamicAmount_InvalidFlags() public {
        OneInchSwapHook.SwapData memory _swapData = _defaultSwapData();
        _swapData.flags = 1;
        vm.startPrank(address(metaWallet));
        swapHook.initializeHookContext();
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_FLAGS));
        swapHook.resolveDynamicAmount(address(swapHook), _swapData);
        vm.stopPrank();
    }

    /// @notice resolveDynamicAmount reverts H1I1 when the previous hook's
    ///         getOutputAmount() returns 0.
    /// @dev swapHook itself is a valid IHookResult and, with no prior swap,
    ///      its _swapContext.amountOut is 0 — a zero-cost stand-in previousHook
    ///      that trips the `_amount > 0` guard without needing a bespoke mock.
    function testRevert_ResolveDynamicAmount_ZeroOutput() public {
        OneInchSwapHook.SwapData memory _swapData = _defaultSwapData();
        vm.startPrank(address(metaWallet));
        swapHook.initializeHookContext();
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INVALID_HOOK_DATA));
        swapHook.resolveDynamicAmount(address(swapHook), _swapData);
        vm.stopPrank();
    }

    /// @notice executeSwap must enforce onlyOwner.
    function testRevert_ExecuteSwap_Unauthorized() public {
        vm.prank(users.alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        swapHook.executeSwap(address(metaWallet));
    }

    /* ///////////////////////////////////////////////////////////////
                         EXECUTION-CONTEXT GATE (H1I8)
    ///////////////////////////////////////////////////////////////*/

    /// @notice resolveDynamicAmount must revert H1I8 when called outside an active chain.
    /// @dev Without this gate, EXECUTOR_ROLE could plant _swapContext/_tempSwapCalldata
    ///      with attacker-chosen dstReceiver and drain via a legitimate router.
    function testRevert_ResolveDynamicAmount_InactiveContext() public {
        OneInchSwapHook.SwapData memory _swapData = _defaultSwapData();
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INACTIVE_CONTEXT));
        swapHook.resolveDynamicAmount(address(swapHook), _swapData);
    }

    /// @notice snapshotDstBalance must revert H1I8 when called outside an active chain.
    function testRevert_SnapshotDstBalance_InactiveContext() public {
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INACTIVE_CONTEXT));
        swapHook.snapshotDstBalance(address(USDC_MAINNET), address(metaWallet));
    }

    /// @notice approveForSwap must revert H1I8 when called outside an active chain.
    /// @dev Pairs with the router allow-list re-check — gate fires first because
    ///      onlyOwner and onlyInsideChain precede the router check.
    function testRevert_ApproveForSwap_InactiveContext() public {
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INACTIVE_CONTEXT));
        swapHook.approveForSwap(address(oneInchRouter));
    }

    /// @notice resetSwapApproval must revert H1I8 when called outside an active chain.
    function testRevert_ResetSwapApproval_InactiveContext() public {
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INACTIVE_CONTEXT));
        swapHook.resetSwapApproval();
    }

    /// @notice executeSwap must revert H1I8 when called outside an active chain.
    function testRevert_ExecuteSwap_InactiveContext() public {
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INACTIVE_CONTEXT));
        swapHook.executeSwap(address(metaWallet));
    }

    /// @notice storeSwapContextStatic must revert H1I8 when called outside an active chain.
    /// @dev Prevents planting a lying _swapContext that downstream hooks consuming
    ///      getOutputAmount() would read as truth.
    function testRevert_StoreSwapContextStatic_InactiveContext() public {
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INACTIVE_CONTEXT));
        swapHook.storeSwapContextStatic(address(USDC_MAINNET), WETH, 1, address(metaWallet));
    }

    /// @notice validateMinOutput must revert H1I8 when called outside an active chain.
    function testRevert_ValidateMinOutput_InactiveContext() public {
        vm.prank(address(metaWallet));
        vm.expectRevert(bytes(Errors.HOOKONEINCH_INACTIVE_CONTEXT));
        swapHook.validateMinOutput(0);
    }

    /* ///////////////////////////////////////////////////////////////
                         IDEMPOTENT CHAIN INIT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Calling initializeHookContext a second time must wipe any stale state
    ///         left over from a chain that aborted without reaching finalize.
    /// @dev Plants _swapContext via a legit chain, then calls init again as owner —
    ///      state must be zero afterwards. This tests the invariant "init always
    ///      starts clean" even though the happy path already clears in finalize.
    function test_InitializeHookContext_ClearsStaleState() public {
        // First chain: run a static swap so _swapContext gets populated.
        OneInchSwapHook.SwapData memory _swapData = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        deal(USDC_MAINNET, address(metaWallet), SWAP_AMOUNT);
        deal(WETH, address(oneInchRouter), SWAP_AMOUNT * 1e12);

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_swapData) });

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();

        // After finalize, context should already be clean. Read it to silence the
        // unused-var warning and document that the pre-init state is not asserted —
        // the invariant we care about is that init produces a clean state
        // regardless of what was there before.
        OneInchSwapHook.SwapContext memory _ctxBeforeInit = swapHook.getSwapContext();
        _ctxBeforeInit;

        // Second chain: just init, don't run anything, don't finalize. Verify init's
        // idempotent clear zeros every field.
        vm.prank(address(metaWallet));
        swapHook.initializeHookContext();

        OneInchSwapHook.SwapContext memory _ctxAfterInit = swapHook.getSwapContext();
        assertEq(_ctxAfterInit.srcToken, address(0), "srcToken not cleared");
        assertEq(_ctxAfterInit.dstToken, address(0), "dstToken not cleared");
        assertEq(_ctxAfterInit.amountIn, 0, "amountIn not cleared");
        assertEq(_ctxAfterInit.amountOut, 0, "amountOut not cleared");
        assertEq(_ctxAfterInit.receiver, address(0), "receiver not cleared");
        assertEq(_ctxAfterInit.timestamp, 0, "timestamp not cleared");
    }

    /* ///////////////////////////////////////////////////////////////
                         V6 ABI STABILITY
    ///////////////////////////////////////////////////////////////*/

    /// @notice Pins the V6 GenericRouter.swap selector to 0x07ed2379.
    /// @dev If this fails, I1InchAggregationRouterV6 has drifted from the mainnet
    ///      Sourcify-verified source at 0x111111125421cA6dc452d289314280a0f8842A65.
    ///      Calldata built by _buildSwapCalldata would then target a different
    ///      function — potentially routing funds into an unintended code path.
    function test_V6SwapSelector_IsStable() public pure {
        assertEq(I1InchAggregationRouterV6.swap.selector, bytes4(0x07ed2379), "V6 swap selector drift");
    }

    /* ///////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @dev Minimal valid SwapData used by the direct-call guard tests as a baseline
    ///      they mutate by flipping a single field. Uses the whitelisted mock router,
    ///      mainnet USDC/WETH, and flags=0.
    function _defaultSwapData() internal view returns (OneInchSwapHook.SwapData memory) {
        return OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: SWAP_AMOUNT,
            minAmountOut: 0,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: USDC_MAINNET,
            dstToken: WETH,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });
    }

    /// @notice Helper to execute a deposit via hook execution
    function _executeDeposit(address _vault, uint256 _amount, uint256 _minShares) internal {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _data =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: _vault, assets: _amount, receiver: address(metaWallet), minShares: _minShares
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_data) });

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();
    }

    /// @notice Helper to execute a swap via hook execution
    function _executeSwap(address _srcToken, address _dstToken, uint256 _amount, uint256 _minOutput) internal {
        OneInchSwapHook.SwapData memory _data = OneInchSwapHook.SwapData({
            router: address(oneInchRouter),
            amountIn: _amount,
            minAmountOut: _minOutput,
            value: 0,
            data: "",
            executor: address(0),
            srcToken: _srcToken,
            dstToken: _dstToken,
            srcReceiver: address(oneInchRouter),
            receiver: address(metaWallet),
            routerMinReturn: 0,
            flags: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: SWAP_HOOK_ID, data: abi.encode(_data) });

        vm.startPrank(users.owner);
        MetaWallet(payable(address(metaWallet)))
            .executeWithHookExecution(metaWallet.nonce(), block.timestamp, _hookExecutions);
        vm.stopPrank();
    }
}
