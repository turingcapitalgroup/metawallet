// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Test Base
import { BaseTest } from "metawallet/test/base/BaseTest.t.sol";

// External Libraries
import { console2 } from "forge-std/console2.sol";
import { ERC1967Factory } from "solady/utils/ERC1967Factory.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Local Contracts
import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { USDC_MAINNET, _1_USDC } from "metawallet/src/helpers/AddressBook.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

// Local Interfaces
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IHookExecution } from "metawallet/src/interfaces/IHookExecution.sol";
import { IHookResult } from "metawallet/src/interfaces/IHookResult.sol";
import { IMetaWallet } from "metawallet/src/interfaces/IMetaWallet.sol";

// Mock Contracts
import { MockRegistry } from "metawallet/test/helpers/mocks/MockRegistry.sol";

// Errors
import "metawallet/src/errors/Errors.sol";

/// @title HookChainTest
/// @notice Comprehensive test suite for hook chaining with real MetaWallet and VaultModule integration
contract HookChainTest is BaseTest {
    using SafeTransferLib for address;

    /* ///////////////////////////////////////////////////////////////
                              CONTRACTS
    ///////////////////////////////////////////////////////////////*/

    IMetaWallet public metaWallet;
    ERC1967Factory public proxyFactory;
    ERC4626ApproveAndDepositHook public depositHook;
    ERC4626RedeemHook public redeemHook;
    MockRegistry public registry;

    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    uint256 public constant INITIAL_BALANCE = 10_000 * _1_USDC; // 10,000 USDC
    uint256 public constant DEPOSIT_AMOUNT = 1000 * _1_USDC; // 1,000 USDC

    bytes32 public constant DEPOSIT_HOOK_ID = keccak256("hook.erc4626.deposit");
    bytes32 public constant REDEEM_HOOK_ID = keccak256("hook.erc4626.redeem");

    address public constant VAULT_A = 0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204;
    address public constant VAULT_B = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    /* ///////////////////////////////////////////////////////////////
                              SETUP
    ///////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Setup base test without fork (local testing)
        _setUp("MAINNET", 23_783_139);
        vm.stopPrank(); // Stop the automatic prank from BaseTest

        // Deploy registry
        registry = new MockRegistry();

        // Deploy proxy factory and MetaWallet implementation
        proxyFactory = new ERC1967Factory();
        MetaWallet _metaWalletImplementation = new MetaWallet();

        // Initialize MetaWallet proxy
        bytes memory _initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, address(registry), "metawallet.hooks.1.0"
        );
        address _metaWalletProxy =
            proxyFactory.deployAndCall(address(_metaWalletImplementation), users.admin, _initData);

        // Grant admin role
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
        depositHook = new ERC4626ApproveAndDepositHook(address(metaWallet));
        redeemHook = new ERC4626RedeemHook(address(metaWallet));

        // Install hooks in the wallet
        vm.startPrank(users.admin);
        MetaWallet(payable(address(metaWallet))).installHook(DEPOSIT_HOOK_ID, address(depositHook));
        MetaWallet(payable(address(metaWallet))).installHook(REDEEM_HOOK_ID, address(redeemHook));
        vm.stopPrank();

        // Whitelist hook contracts and vaults in registry
        registry.whitelistTarget(address(depositHook));
        registry.whitelistTarget(address(redeemHook));
        registry.whitelistTarget(address(USDC_MAINNET));
        registry.whitelistTarget(address(VAULT_A));
        registry.whitelistTarget(address(VAULT_B));

        // Setup initial balances for the wallet
        deal(USDC_MAINNET, address(metaWallet), INITIAL_BALANCE);

        // Setup Alice with USDC and approval
        vm.startPrank(users.alice);
        USDC_MAINNET.safeApprove(address(metaWallet), type(uint256).max);
        vm.stopPrank();

        // Label addresses for better trace output
        vm.label(address(depositHook), "DepositHook");
        vm.label(address(redeemHook), "RedeemHook");
        vm.label(address(metaWallet), "MetaWallet");
        vm.label(address(registry), "Registry");
        vm.label(address(USDC_MAINNET), "USDC");
        vm.label(address(VAULT_A), "VaultA");
        vm.label(address(VAULT_B), "VaultB");
    }

    /* ///////////////////////////////////////////////////////////////
                         STATIC AMOUNT TESTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Test single deposit hook with static amount
    function test_SingleDepositHook_StaticAmount() public {
        // Encode deposit data with static amount
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        // Create hook execution array
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        // Record balances before
        uint256 _usdcBalanceBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceBefore = VAULT_A.balanceOf(address(metaWallet));

        // Execute through the real wallet as owner
        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        // Record balances after
        uint256 _usdcBalanceAfter = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceAfter = VAULT_A.balanceOf(address(metaWallet));

        // Assertions
        assertEq(_usdcBalanceBefore - _usdcBalanceAfter, DEPOSIT_AMOUNT, "USDC should be spent");
        assertGt(_sharesBalanceAfter, _sharesBalanceBefore, "Should receive shares");
    }

    /// @notice Test single redeem hook with static amount
    function test_SingleRedeemHook_StaticAmount() public {
        // First deposit to get shares
        uint256 _sharesToRedeem = _depositToVault(address(VAULT_A), DEPOSIT_AMOUNT);

        // Encode redeem data with static amount
        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: _sharesToRedeem,
            receiver: address(metaWallet),
            owner: address(metaWallet),
            minAssets: 0
        });

        // Create hook execution array
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });

        // Record balances before
        uint256 _usdcBalanceBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceBefore = VAULT_A.balanceOf(address(metaWallet));

        // Execute through the real wallet as owner
        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        // Record balances after
        uint256 _usdcBalanceAfter = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceAfter = VAULT_A.balanceOf(address(metaWallet));

        // Assertions
        assertEq(_sharesBalanceBefore - _sharesBalanceAfter, _sharesToRedeem, "Shares should be burned");
        assertGt(_usdcBalanceAfter, _usdcBalanceBefore, "Should receive USDC");
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT TESTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Test deposit → redeem chain with dynamic amount
    function test_DepositThenRedeem_DynamicAmount() public {
        // Step 1: Deposit with static amount
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        // Step 2: Redeem with DYNAMIC amount (reads from deposit hook output)
        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC!
            receiver: address(metaWallet),
            owner: address(metaWallet),
            minAssets: 0
        });

        // Create hook execution array with both hooks
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](2);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });

        // Record initial state
        uint256 _usdcStart = USDC_MAINNET.balanceOf(address(metaWallet));

        // Execute the complete chain through the real wallet
        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        // Record final state
        uint256 _usdcEnd = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesEnd = VAULT_A.balanceOf(address(metaWallet));

        // Assertions
        assertEq(_sharesEnd, 0, "All shares should be redeemed");
        assertApproxEqAbs(_usdcEnd, _usdcStart, 10, "Should get back approximately same USDC (minus rounding)");
    }

    /// @notice Test vault hopping with dynamic amounts
    function test_VaultHopping_DynamicAmounts() public {
        // Step 1: Deposit USDC into Vault A
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositDataA =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        // Step 2: Redeem from Vault A with DYNAMIC amount
        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC!
            receiver: address(depositHook),
            owner: address(metaWallet),
            minAssets: 0
        });

        // Step 3: Deposit into Vault B with DYNAMIC amount from redeem
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositDataB =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_B),
                assets: depositHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC!
                receiver: address(metaWallet),
                minShares: 0
            });

        // Create hook execution array with all three hooks
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositDataA) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositDataB) });

        // Execute the complete chain through the real wallet
        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        // Record final state
        uint256 _sharesA = VAULT_A.balanceOf(address(metaWallet));
        uint256 _sharesB = VAULT_B.balanceOf(address(metaWallet));

        // Assertions
        assertEq(_sharesA, 0, "No shares left in Vault A");
        assertGt(_sharesB, 0, "Should have shares in Vault B");
        // Scale decimals because vault is denominated in 6 decimals
        assertApproxEqRel(
            _sharesB, DEPOSIT_AMOUNT * 1e12, 0.1 ether, "Shares should be approximately equal to initial deposit"
        );
    }

    /// @notice Test complex chain with slippage protection
    function test_ComplexChain_WithSlippageProtection() public {
        uint256 _initialUsdc = USDC_MAINNET.balanceOf(address(metaWallet));

        // Chain 1: Deposit 1000 USDC to Vault A with slippage protection
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _deposit1 =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A),
                assets: DEPOSIT_AMOUNT,
                receiver: address(metaWallet),
                minShares: 900e6 // Expect at least 900 shares
            });

        // Chain 2: Redeem ALL shares from Vault A (dynamic amount) with slippage protection
        ERC4626RedeemHook.RedeemData memory _redeem1 = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(),
            receiver: address(depositHook),
            owner: address(metaWallet),
            minAssets: 950e6 // Expect at least 950 USDC back
        });

        // Chain 3: Deposit ALL USDC to Vault B (dynamic amount)
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _deposit2 =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_B),
                assets: depositHook.USE_PREVIOUS_HOOK_OUTPUT(),
                receiver: address(metaWallet),
                minShares: 0
            });

        // Create hook execution array
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_deposit1) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeem1) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_deposit2) });

        // Execute the complete chain
        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        // Final assertions
        uint256 _sharesA = VAULT_A.balanceOf(address(metaWallet));
        uint256 _sharesB = VAULT_B.balanceOf(address(metaWallet));

        assertEq(_sharesA, 0, "No shares in Vault A");
        assertGt(_sharesB, 0, "Should have shares in Vault B");
    }

    /* ///////////////////////////////////////////////////////////////
                         ERROR CASE TESTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Test that dynamic amount fails without previous hook
    function testRevert_DynamicAmount_NoPreviousHook() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A),
                assets: depositHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC!
                receiver: address(metaWallet),
                minShares: 0
            });

        // Create hook execution with only one hook (no previous)
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        // This should fail because previousHook is address(0)
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /// @notice Test slippage protection with minimum shares
    function testRevert_SlippageProtection_InsufficientShares() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A),
                assets: DEPOSIT_AMOUNT,
                receiver: address(metaWallet),
                minShares: type(uint256).max // Impossible to achieve
            });

        // Create hook execution array
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        // This should fail due to slippage check
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(HOOK4626DEPOSIT_INSUFFICIENT_SHARES));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /// @notice Test that non-owner cannot execute hooks
    function testRevert_UnauthorizedExecution() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        // Create hook execution array
        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        // This should fail because alice is not authorized
        vm.startPrank(users.alice);
        vm.expectRevert("Unauthorized()");
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    /* ///////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Helper to deposit assets directly and return shares received
    function _depositToVault(address _vault, uint256 _amount) internal returns (uint256 _shares) {
        vm.startPrank(address(metaWallet));
        USDC_MAINNET.safeApprove(_vault, _amount);
        _shares = IERC4626(_vault).deposit(_amount, address(metaWallet));
        vm.stopPrank();
    }
}
