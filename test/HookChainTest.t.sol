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

    function test_SingleDepositHook_StaticAmount() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        uint256 _usdcBalanceBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceBefore = VAULT_A.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _usdcBalanceAfter = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceAfter = VAULT_A.balanceOf(address(metaWallet));

        assertEq(_usdcBalanceBefore - _usdcBalanceAfter, DEPOSIT_AMOUNT);
        assertGt(_sharesBalanceAfter, _sharesBalanceBefore);
    }

    function test_SingleRedeemHook_StaticAmount() public {
        uint256 _sharesToRedeem = _depositToVault(address(VAULT_A), DEPOSIT_AMOUNT);

        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: _sharesToRedeem,
            receiver: address(metaWallet),
            owner: address(metaWallet),
            minAssets: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });

        uint256 _usdcBalanceBefore = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceBefore = VAULT_A.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _usdcBalanceAfter = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesBalanceAfter = VAULT_A.balanceOf(address(metaWallet));

        assertEq(_sharesBalanceBefore - _sharesBalanceAfter, _sharesToRedeem);
        assertGt(_usdcBalanceAfter, _usdcBalanceBefore);
    }

    /* ///////////////////////////////////////////////////////////////
                         DYNAMIC AMOUNT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_DepositThenRedeem_DynamicAmount() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC!
            receiver: address(metaWallet),
            owner: address(metaWallet),
            minAssets: 0
        });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](2);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });

        uint256 _usdcStart = USDC_MAINNET.balanceOf(address(metaWallet));

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _usdcEnd = USDC_MAINNET.balanceOf(address(metaWallet));
        uint256 _sharesEnd = VAULT_A.balanceOf(address(metaWallet));

        assertEq(_sharesEnd, 0);
        assertApproxEqAbs(_usdcEnd, _usdcStart, 10);
    }

    function test_VaultHopping_DynamicAmounts() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositDataA =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC
            receiver: address(depositHook),
            owner: address(metaWallet),
            minAssets: 0
        });

        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositDataB =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_B),
                assets: depositHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC
                receiver: address(metaWallet),
                minShares: 0
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositDataA) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositDataB) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _sharesA = VAULT_A.balanceOf(address(metaWallet));
        uint256 _sharesB = VAULT_B.balanceOf(address(metaWallet));

        assertEq(_sharesA, 0);
        assertGt(_sharesB, 0);
        // Scale decimals because vault uses 18 decimals
        assertApproxEqRel(
            _sharesB, DEPOSIT_AMOUNT * 1e12, 0.1 ether
        );
    }

    function test_ComplexChain_WithSlippageProtection() public {
        uint256 _initialUsdc = USDC_MAINNET.balanceOf(address(metaWallet));

        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _deposit1 =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A),
                assets: DEPOSIT_AMOUNT,
                receiver: address(metaWallet),
                minShares: 900e6 // Expect at least 900 shares
            });

        ERC4626RedeemHook.RedeemData memory _redeem1 = ERC4626RedeemHook.RedeemData({
            vault: address(VAULT_A),
            shares: redeemHook.USE_PREVIOUS_HOOK_OUTPUT(),
            receiver: address(depositHook),
            owner: address(metaWallet),
            minAssets: 950e6 // Expect at least 950 USDC back
        });

        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _deposit2 =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_B),
                assets: depositHook.USE_PREVIOUS_HOOK_OUTPUT(),
                receiver: address(metaWallet),
                minShares: 0
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](3);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_deposit1) });
        _hookExecutions[1] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeem1) });
        _hookExecutions[2] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_deposit2) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        uint256 _sharesA = VAULT_A.balanceOf(address(metaWallet));
        uint256 _sharesB = VAULT_B.balanceOf(address(metaWallet));

        assertEq(_sharesA, 0);
        assertGt(_sharesB, 0);
    }

    /* ///////////////////////////////////////////////////////////////
                         ERROR CASE TESTS
    ///////////////////////////////////////////////////////////////*/

    function testRevert_DynamicAmount_NoPreviousHook() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A),
                assets: depositHook.USE_PREVIOUS_HOOK_OUTPUT(), // DYNAMIC
                receiver: address(metaWallet),
                minShares: 0
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        vm.startPrank(users.owner);
        vm.expectRevert(bytes(HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_SlippageProtection_InsufficientShares() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A),
                assets: DEPOSIT_AMOUNT,
                receiver: address(metaWallet),
                minShares: type(uint256).max // Impossible to achieve
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        // This should fail due to slippage check
        vm.startPrank(users.owner);
        vm.expectRevert(bytes(HOOK4626DEPOSIT_INSUFFICIENT_SHARES));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);
    }

    function testRevert_UnauthorizedExecution() public {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: address(VAULT_A), assets: DEPOSIT_AMOUNT, receiver: address(metaWallet), minShares: 0
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

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
