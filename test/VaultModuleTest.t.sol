// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { BaseTest } from "metawallet/test/base/BaseTest.t.sol";

import { ERC1967Factory } from "solady/utils/ERC1967Factory.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { USDC_MAINNET, _1_USDC } from "metawallet/src/helpers/AddressBook.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { ERC4626, ERC7540 } from "metawallet/src/lib/ERC7540.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IHookExecution } from "metawallet/src/interfaces/IHookExecution.sol";
import { IMetaWallet } from "metawallet/src/interfaces/IMetaWallet.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";

import { MockRegistry } from "metawallet/test/helpers/mocks/MockRegistry.sol";

import { ERC4626Events } from "metawallet/test/helpers/ERC4626Events.sol";
import { ERC7540Events } from "metawallet/test/helpers/ERC7540Events.sol";

contract VaultModuleTest is BaseTest, ERC7540Events, ERC4626Events {
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

    uint256 public constant INITIAL_BALANCE = 100_000 * _1_USDC;
    uint256 public constant DEPOSIT_AMOUNT = 10_000 * _1_USDC;
    uint256 public constant SMALL_DEPOSIT = 100 * _1_USDC;

    bytes32 public constant DEPOSIT_HOOK_ID = keccak256("hook.erc4626.deposit");
    bytes32 public constant REDEEM_HOOK_ID = keccak256("hook.erc4626.redeem");

    address public constant EXTERNAL_VAULT_A = 0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204;
    address public constant EXTERNAL_VAULT_B = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address public constant EXTERNAL_VAULT = EXTERNAL_VAULT_A;

    uint256 public constant ADMIN_ROLE = 1; // _ROLE_0
    uint256 public constant WHITELISTED_ROLE = 2; // _ROLE_1
    uint256 public constant EXECUTOR_ROLE = 2; // _ROLE_1 (same as WHITELISTED_ROLE)
    uint256 public constant MANAGER_ROLE = 16; // _ROLE_4
    uint256 public constant EMERGENCY_ADMIN_ROLE = 64; // _ROLE_6

    /* ///////////////////////////////////////////////////////////////
                              SETUP
    ///////////////////////////////////////////////////////////////*/

    function setUp() public {
        _setUp("MAINNET", 23_783_139);
        vm.stopPrank();

        registry = new MockRegistry();

        proxyFactory = new ERC1967Factory();
        MetaWallet _metaWalletImplementation = new MetaWallet();

        bytes memory _initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, address(registry), "metawallet.vault.test.1.0"
        );
        address _metaWalletProxy =
            proxyFactory.deployAndCall(address(_metaWalletImplementation), users.admin, _initData);

        vm.startPrank(users.owner);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.admin, ADMIN_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.owner, EXECUTOR_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.executor, MANAGER_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.charlie, EMERGENCY_ADMIN_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.alice, WHITELISTED_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.bob, WHITELISTED_ROLE);
        vm.stopPrank();

        VaultModule _vault = new VaultModule();
        bytes4[] memory _vaultSelectors = _vault.selectors();

        vm.startPrank(users.admin);
        MetaWallet(payable(_metaWalletProxy)).addFunctions(_vaultSelectors, address(_vault), false);
        VaultModule(_metaWalletProxy).initializeVault(address(USDC_MAINNET), "Meta USDC", "mUSDC");
        vm.stopPrank();

        metaWallet = IMetaWallet(_metaWalletProxy);

        depositHook = new ERC4626ApproveAndDepositHook(address(metaWallet));
        redeemHook = new ERC4626RedeemHook(address(metaWallet));

        vm.startPrank(users.admin);
        MetaWallet(payable(address(metaWallet))).installHook(DEPOSIT_HOOK_ID, address(depositHook));
        MetaWallet(payable(address(metaWallet))).installHook(REDEEM_HOOK_ID, address(redeemHook));
        vm.stopPrank();

        registry.whitelistTarget(address(depositHook));
        registry.whitelistTarget(address(redeemHook));
        registry.whitelistTarget(address(USDC_MAINNET));
        registry.whitelistTarget(address(EXTERNAL_VAULT_A));
        registry.whitelistTarget(address(EXTERNAL_VAULT_B));

        vm.prank(users.alice);
        USDC_MAINNET.safeApprove(address(metaWallet), type(uint256).max);

        vm.prank(users.bob);
        USDC_MAINNET.safeApprove(address(metaWallet), type(uint256).max);

        vm.label(address(depositHook), "DepositHook");
        vm.label(address(redeemHook), "RedeemHook");
        vm.label(address(metaWallet), "MetaWallet");
        vm.label(address(registry), "Registry");
        vm.label(address(USDC_MAINNET), "USDC");
        vm.label(address(EXTERNAL_VAULT_A), "VaultA");
        vm.label(address(EXTERNAL_VAULT_B), "VaultB");
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 1: REQUEST DEPOSIT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_RequestDeposit_Success() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);

        uint256 _usdcBefore = USDC_MAINNET.balanceOf(users.alice);
        uint256 _walletBalanceBefore = USDC_MAINNET.balanceOf(address(metaWallet));

        vm.expectEmit();
        emit DepositRequest(users.alice, users.alice, 0, users.alice, _depositAmount);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        assertEq(USDC_MAINNET.balanceOf(users.alice), _usdcBefore - _depositAmount);
        assertEq(USDC_MAINNET.balanceOf(address(metaWallet)), _walletBalanceBefore + _depositAmount);
        assertEq(metaWallet.claimableDepositRequest(users.alice), _depositAmount);
        assertEq(metaWallet.pendingDepositRequest(users.alice), 0);
        assertEq(metaWallet.totalAssets(), 0);
        assertEq(metaWallet.balanceOf(users.alice), 0);

        vm.stopPrank();
    }

    function test_RequestDeposit_MultipleUsers() public {
        uint256 _aliceDeposit = DEPOSIT_AMOUNT;
        uint256 _bobDeposit = DEPOSIT_AMOUNT * 2;

        deal(USDC_MAINNET, users.alice, _aliceDeposit);
        deal(USDC_MAINNET, users.bob, _bobDeposit);

        vm.prank(users.alice);
        metaWallet.requestDeposit(_aliceDeposit, users.alice, users.alice);

        vm.prank(users.bob);
        metaWallet.requestDeposit(_bobDeposit, users.bob, users.bob);

        assertEq(metaWallet.claimableDepositRequest(users.alice), _aliceDeposit);
        assertEq(metaWallet.claimableDepositRequest(users.bob), _bobDeposit);
        assertEq(USDC_MAINNET.balanceOf(address(metaWallet)), _aliceDeposit + _bobDeposit);
    }

    function testRevert_RequestDeposit_ZeroAssets() public {
        vm.prank(users.alice);
        vm.expectRevert(ERC7540.InvalidZeroAssets.selector);
        metaWallet.requestDeposit(0, users.alice, users.alice);
    }

    function testRevert_RequestDeposit_InvalidOwner() public {
        deal(USDC_MAINNET, users.alice, DEPOSIT_AMOUNT);

        vm.prank(users.alice);
        vm.expectRevert(ERC7540.InvalidOperator.selector);
        metaWallet.requestDeposit(DEPOSIT_AMOUNT, users.alice, users.bob);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 2: DEPOSIT (CLAIM) TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Deposit_Success() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        uint256 _sharePriceBefore = metaWallet.sharePrice();

        vm.expectEmit();
        emit Deposit(users.alice, users.alice, _depositAmount, _depositAmount);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);

        assertEq(_shares, _depositAmount);
        assertEq(metaWallet.balanceOf(users.alice), _shares);
        assertEq(metaWallet.totalSupply(), _shares);
        assertEq(metaWallet.totalAssets(), _depositAmount);
        assertEq(metaWallet.totalIdle(), _depositAmount);
        assertEq(metaWallet.claimableDepositRequest(users.alice), 0);

        uint256 _sharePriceAfter = metaWallet.sharePrice();
        assertEq(_sharePriceAfter, _sharePriceBefore);

        vm.stopPrank();
    }

    function test_Deposit_PartialClaim() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        uint256 _claimAmount = _depositAmount / 2;
        uint256 _shares = metaWallet.deposit(_claimAmount, users.alice);

        assertEq(_shares, _claimAmount);
        assertEq(metaWallet.balanceOf(users.alice), _claimAmount);
        assertEq(metaWallet.claimableDepositRequest(users.alice), _depositAmount - _claimAmount);
        assertEq(metaWallet.totalAssets(), _claimAmount);

        vm.stopPrank();
    }

    function test_Mint_Success() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        vm.expectEmit();
        emit Deposit(users.alice, users.alice, _depositAmount, _depositAmount);
        uint256 _assets = metaWallet.mint(_depositAmount, users.alice);

        assertEq(_assets, _depositAmount);
        assertEq(metaWallet.balanceOf(users.alice), _depositAmount);

        vm.stopPrank();
    }

    function testRevert_Deposit_NoRequest() public {
        vm.prank(users.alice);
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        metaWallet.deposit(DEPOSIT_AMOUNT, users.alice);
    }

    function testRevert_Deposit_ExceedsClaimable() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        metaWallet.deposit(_depositAmount + 1, users.alice);

        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 3: REQUEST REDEEM TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_Success() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);

        uint256 _sharePriceBefore = metaWallet.sharePrice();

        vm.expectEmit();
        emit RedeemRequest(users.alice, users.alice, 0, users.alice, _shares);
        metaWallet.requestRedeem(_shares, users.alice, users.alice);

        uint256 _sharePriceAfter = metaWallet.sharePrice();
        assertEq(_sharePriceAfter, _sharePriceBefore);

        assertEq(metaWallet.balanceOf(users.alice), 0);
        assertEq(metaWallet.balanceOf(address(metaWallet)), _shares);
        assertEq(metaWallet.claimableRedeemRequest(users.alice), _shares);
        assertEq(metaWallet.pendingRedeemRequest(users.alice), 0);

        vm.stopPrank();
    }

    function testRevert_RequestRedeem_ZeroShares() public {
        vm.prank(users.alice);
        vm.expectRevert(ERC7540.InvalidZeroShares.selector);
        metaWallet.requestRedeem(0, users.alice, users.alice);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 4: REDEEM TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Redeem_Success() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);
        metaWallet.requestRedeem(_shares, users.alice, users.alice);

        uint256 _sharePriceBefore = metaWallet.sharePrice();
        uint256 _aliceUsdcBefore = USDC_MAINNET.balanceOf(users.alice);

        vm.expectEmit();
        emit Withdraw(users.alice, users.alice, users.alice, _depositAmount, _shares);
        uint256 _assets = metaWallet.redeem(_shares, users.alice, users.alice);

        uint256 _sharePriceAfter = metaWallet.sharePrice();
        assertEq(_sharePriceAfter, _sharePriceBefore);

        assertEq(_assets, _depositAmount);
        assertEq(USDC_MAINNET.balanceOf(users.alice), _aliceUsdcBefore + _depositAmount);
        assertEq(metaWallet.totalSupply(), 0);
        assertEq(metaWallet.totalAssets(), 0);
        assertEq(metaWallet.claimableRedeemRequest(users.alice), 0);

        vm.stopPrank();
    }

    function test_Withdraw_Success() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);
        metaWallet.requestRedeem(_shares, users.alice, users.alice);

        uint256 _aliceUsdcBefore = USDC_MAINNET.balanceOf(users.alice);

        vm.expectEmit();
        emit Withdraw(users.alice, users.alice, users.alice, _depositAmount, _shares);
        uint256 _burntShares = metaWallet.withdraw(_depositAmount, users.alice, users.alice);

        assertEq(_burntShares, _shares);
        assertEq(USDC_MAINNET.balanceOf(users.alice), _aliceUsdcBefore + _depositAmount);

        vm.stopPrank();
    }

    function testRevert_Redeem_NoRequest() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);

        vm.expectRevert(ERC4626.RedeemMoreThanMax.selector);
        metaWallet.redeem(_depositAmount, users.alice, users.alice);

        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 5: SHARE PRICE STABILITY TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_SharePrice_StableWithNoGainsOrLosses() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        uint256 _initialSharePrice = metaWallet.sharePrice();

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        uint256 _afterRequestSharePrice = metaWallet.sharePrice();
        assertEq(_afterRequestSharePrice, _initialSharePrice);

        metaWallet.deposit(_depositAmount, users.alice);

        uint256 _afterDepositSharePrice = metaWallet.sharePrice();
        assertEq(_afterDepositSharePrice, _initialSharePrice);

        vm.stopPrank();

        deal(USDC_MAINNET, users.bob, _depositAmount * 2);

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_depositAmount * 2, users.bob, users.bob);
        metaWallet.deposit(_depositAmount * 2, users.bob);

        uint256 _afterBobSharePrice = metaWallet.sharePrice();
        assertEq(_afterBobSharePrice, _initialSharePrice);

        vm.stopPrank();

        vm.startPrank(users.alice);
        uint256 _aliceShares = metaWallet.balanceOf(users.alice);
        metaWallet.requestRedeem(_aliceShares, users.alice, users.alice);

        uint256 _afterRedeemRequestSharePrice = metaWallet.sharePrice();
        assertEq(_afterRedeemRequestSharePrice, _initialSharePrice);

        metaWallet.redeem(_aliceShares, users.alice, users.alice);

        uint256 _afterRedeemSharePrice = metaWallet.sharePrice();
        assertEq(_afterRedeemSharePrice, _initialSharePrice);

        vm.stopPrank();
    }

    function test_SharePrice_FirstDepositor_OneToOne() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);

        assertEq(_shares, _depositAmount);
        assertEq(metaWallet.convertToShares(_depositAmount), _depositAmount);
        assertEq(metaWallet.convertToAssets(_shares), _depositAmount);

        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 6: SETTLEMENT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_SettleTotalAssets_Success() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _newTotalAssets = 15_000 * _1_USDC;
        bytes32 _merkleRoot = keccak256(abi.encodePacked(EXTERNAL_VAULT, _newTotalAssets - _depositAmount));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets);
        assertEq(metaWallet.merkleRoot(), _merkleRoot);
    }

    function testRevert_SettleTotalAssets_Unauthorized() public {
        uint256 _newTotalAssets = 5000 * _1_USDC;
        bytes32 _merkleRoot = keccak256(abi.encodePacked(EXTERNAL_VAULT, _newTotalAssets));

        vm.prank(users.alice);
        vm.expectRevert();
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 7: PAUSE TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Pause_Success() public {
        vm.prank(users.charlie);
        metaWallet.pause();

        assertTrue(metaWallet.paused());
    }

    function test_Unpause_Success() public {
        vm.prank(users.charlie);
        metaWallet.pause();

        vm.prank(users.charlie);
        metaWallet.unpause();

        assertFalse(metaWallet.paused());
    }

    function testRevert_Pause_Unauthorized() public {
        vm.prank(users.alice);
        vm.expectRevert();
        metaWallet.pause();
    }

    function testRevert_Unpause_Unauthorized() public {
        vm.prank(users.charlie);
        metaWallet.pause();

        vm.prank(users.alice);
        vm.expectRevert();
        metaWallet.unpause();
    }

    function testRevert_RequestDeposit_WhenPaused() public {
        vm.prank(users.charlie);
        metaWallet.pause();

        deal(USDC_MAINNET, users.alice, DEPOSIT_AMOUNT);

        vm.prank(users.alice);
        vm.expectRevert(bytes("MW1"));
        metaWallet.requestDeposit(DEPOSIT_AMOUNT, users.alice, users.alice);
    }

    function testRevert_Deposit_WhenPaused() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.prank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        vm.prank(users.charlie);
        metaWallet.pause();

        vm.prank(users.alice);
        vm.expectRevert(bytes("MW1"));
        metaWallet.deposit(_depositAmount, users.alice);
    }

    function testRevert_Redeem_WhenPaused() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);
        metaWallet.requestRedeem(_shares, users.alice, users.alice);
        vm.stopPrank();

        vm.prank(users.charlie);
        metaWallet.pause();

        vm.prank(users.alice);
        vm.expectRevert(bytes("MW1"));
        metaWallet.redeem(_shares, users.alice, users.alice);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 8: ACCOUNTING TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Accounting_TotalAssets_AfterDeposit() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        assertEq(metaWallet.totalAssets(), 0);
        assertEq(metaWallet.totalIdle(), 0);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);

        assertEq(metaWallet.totalAssets(), 0);
        assertEq(metaWallet.totalIdle(), 0);

        metaWallet.deposit(_depositAmount, users.alice);

        assertEq(metaWallet.totalAssets(), _depositAmount);
        assertEq(metaWallet.totalIdle(), _depositAmount);

        vm.stopPrank();
    }

    function test_Accounting_TotalAssets_WithSettlement() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _newTotalAssets = _depositAmount + 5000 * _1_USDC;
        bytes32 _merkleRoot = keccak256(abi.encodePacked(EXTERNAL_VAULT, 5000 * _1_USDC));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets);
    }

    function test_Accounting_SharePrice_IncreasesWithYield() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _sharePriceBefore = metaWallet.sharePrice();

        uint256 _yield = 1000 * _1_USDC;
        uint256 _newTotalAssets = _depositAmount + _yield;
        bytes32 _merkleRoot = keccak256(abi.encodePacked(EXTERNAL_VAULT, _yield));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        uint256 _sharePriceAfter = metaWallet.sharePrice();
        assertGt(_sharePriceAfter, _sharePriceBefore);

        uint256 _expectedAssets = metaWallet.convertToAssets(_shares);
        assertGt(_expectedAssets, _depositAmount);
    }

    function test_Accounting_SharePrice_DecreasesWithLoss() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _sharePriceBefore = metaWallet.sharePrice();

        uint256 _loss = 2000 * _1_USDC;
        uint256 _newTotalAssets = _depositAmount - _loss;
        bytes32 _merkleRoot = keccak256(abi.encodePacked("loss"));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        uint256 _sharePriceAfter = metaWallet.sharePrice();
        assertLt(_sharePriceAfter, _sharePriceBefore);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 9: STRATEGY INVESTMENT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_InvestInStrategy_TotalAssetsStable() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _totalAssetsBefore = metaWallet.totalAssets();
        uint256 _sharePriceBefore = metaWallet.sharePrice();

        uint256 _investAmount = _depositAmount / 2;

        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: EXTERNAL_VAULT, assets: _investAmount, receiver: address(metaWallet), minShares: 0
            });

        IHookExecution.HookExecution[] memory _hookExecutions = new IHookExecution.HookExecution[](1);
        _hookExecutions[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hookExecutions);

        assertEq(metaWallet.totalAssets(), _totalAssetsBefore);
        assertEq(metaWallet.sharePrice(), _sharePriceBefore);
        assertEq(metaWallet.totalIdle(), _depositAmount - _investAmount);
    }

    function test_DivestFromStrategy_UsingRedeemHook() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _investAmount = _depositAmount / 2;

        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: EXTERNAL_VAULT, assets: _investAmount, receiver: address(metaWallet), minShares: 0
            });

        IHookExecution.HookExecution[] memory _investHooks = new IHookExecution.HookExecution[](1);
        _investHooks[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_investHooks);

        uint256 _externalShares = IERC4626(EXTERNAL_VAULT).balanceOf(address(metaWallet));
        uint256 _totalIdleBefore = metaWallet.totalIdle();

        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: EXTERNAL_VAULT,
            shares: _externalShares,
            receiver: address(metaWallet),
            owner: address(metaWallet),
            minAssets: 0
        });

        IHookExecution.HookExecution[] memory _divestHooks = new IHookExecution.HookExecution[](1);
        _divestHooks[0] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_divestHooks);

        uint256 _totalIdleAfter = metaWallet.totalIdle();
        uint256 _externalSharesAfter = IERC4626(EXTERNAL_VAULT).balanceOf(address(metaWallet));

        assertEq(_externalSharesAfter, 0);
        assertGt(_totalIdleAfter, _totalIdleBefore);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 10: MERKLE VALIDATION TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_ValidateTotalAssets_Success() public view {
        address[] memory _strategies = new address[](2);
        uint256[] memory _values = new uint256[](2);

        _strategies[0] = EXTERNAL_VAULT;
        _strategies[1] = address(0x1234);
        _values[0] = 5000 * _1_USDC;
        _values[1] = 3000 * _1_USDC;

        bytes32[] memory _leaves = new bytes32[](2);
        _leaves[0] = keccak256(abi.encodePacked(_strategies[0], _values[0]));
        _leaves[1] = keccak256(abi.encodePacked(_strategies[1], _values[1]));
        bytes32 _merkleRoot = MerkleTreeLib.root(_leaves);

        bool _isValid = metaWallet.validateTotalAssets(_strategies, _values, _merkleRoot);
        assertTrue(_isValid);
    }

    function test_ValidateTotalAssets_Failure() public view {
        address[] memory _strategies = new address[](1);
        uint256[] memory _values = new uint256[](1);

        _strategies[0] = EXTERNAL_VAULT;
        _values[0] = 5000 * _1_USDC;

        bytes32 _wrongMerkleRoot = keccak256(abi.encodePacked("wrong"));

        bool _isValid = metaWallet.validateTotalAssets(_strategies, _values, _wrongMerkleRoot);
        assertFalse(_isValid);
    }

    function testRevert_ValidateTotalAssets_MismatchedArrays() public {
        address[] memory _strategies = new address[](2);
        uint256[] memory _values = new uint256[](1);

        _strategies[0] = EXTERNAL_VAULT;
        _strategies[1] = address(0x1234);
        _values[0] = 5000 * _1_USDC;

        vm.expectRevert(bytes("MW2"));
        metaWallet.validateTotalAssets(_strategies, _values, bytes32(0));
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 11: MULTI-USER SCENARIOS
    ///////////////////////////////////////////////////////////////*/

    function test_MultiUser_DepositAndRedeem_SharePriceStable() public {
        uint256 _aliceDeposit = DEPOSIT_AMOUNT;
        uint256 _bobDeposit = DEPOSIT_AMOUNT * 2;

        deal(USDC_MAINNET, users.alice, _aliceDeposit);
        deal(USDC_MAINNET, users.bob, _bobDeposit);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_aliceDeposit, users.alice, users.alice);
        uint256 _aliceShares = metaWallet.deposit(_aliceDeposit, users.alice);
        vm.stopPrank();

        uint256 _sharePriceAfterAlice = metaWallet.sharePrice();

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_bobDeposit, users.bob, users.bob);
        metaWallet.deposit(_bobDeposit, users.bob);
        vm.stopPrank();

        uint256 _sharePriceAfterBob = metaWallet.sharePrice();
        assertEq(_sharePriceAfterBob, _sharePriceAfterAlice);

        vm.startPrank(users.alice);
        metaWallet.requestRedeem(_aliceShares, users.alice, users.alice);
        metaWallet.redeem(_aliceShares, users.alice, users.alice);
        vm.stopPrank();

        uint256 _sharePriceAfterAliceRedeem = metaWallet.sharePrice();
        assertEq(_sharePriceAfterAliceRedeem, _sharePriceAfterBob);
    }

    function test_MultiUser_ShareProportions() public {
        uint256 _aliceDeposit = 1000 * _1_USDC;
        uint256 _bobDeposit = 3000 * _1_USDC;

        deal(USDC_MAINNET, users.alice, _aliceDeposit);
        deal(USDC_MAINNET, users.bob, _bobDeposit);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_aliceDeposit, users.alice, users.alice);
        uint256 _aliceShares = metaWallet.deposit(_aliceDeposit, users.alice);
        vm.stopPrank();

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_bobDeposit, users.bob, users.bob);
        uint256 _bobShares = metaWallet.deposit(_bobDeposit, users.bob);
        vm.stopPrank();

        uint256 _totalShares = metaWallet.totalSupply();

        assertEq(_aliceShares * 4, _totalShares);
        assertEq(_bobShares, _totalShares * 3 / 4);

        uint256 _yield = 400 * _1_USDC;
        uint256 _newTotalAssets = _aliceDeposit + _bobDeposit + _yield;
        bytes32 _merkleRoot = keccak256(abi.encodePacked(EXTERNAL_VAULT, _yield));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        uint256 _aliceValue = metaWallet.convertToAssets(_aliceShares);
        uint256 _bobValue = metaWallet.convertToAssets(_bobShares);

        assertApproxEqAbs(_aliceValue, _aliceDeposit + _yield / 4, 1);
        assertApproxEqAbs(_bobValue, _bobDeposit + (_yield * 3 / 4), 1);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 12: EDGE CASES AND INVARIANTS
    ///////////////////////////////////////////////////////////////*/

    function test_Invariant_TotalSupplyBackedByAssets() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _totalSupply = metaWallet.totalSupply();
        uint256 _totalAssets = metaWallet.totalAssets();

        assertGe(_totalAssets, _totalSupply);
    }

    function test_ConvertToShares_AndBack() public {
        uint256 _depositAmount = DEPOSIT_AMOUNT;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _assets = 1000 * _1_USDC;
        uint256 _shares = metaWallet.convertToShares(_assets);
        uint256 _assetsBack = metaWallet.convertToAssets(_shares);

        assertEq(_assetsBack, _assets);
    }

    function test_ZeroTotalSupply_SharePriceIsOneToOne() public view {
        uint256 _sharePrice = metaWallet.sharePrice();
        assertEq(_sharePrice, 10 ** 6);

        uint256 _assets = 1000 * _1_USDC;
        uint256 _shares = metaWallet.convertToShares(_assets);
        assertEq(_shares, _assets);
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 13: FULL LIFECYCLE TEST
    ///////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_DepositInvestYieldSettleRedeem() public {
        _setupUsersDeposits();

        uint256 _aliceShares = metaWallet.balanceOf(users.alice);
        uint256 _bobShares = metaWallet.balanceOf(users.bob);
        uint256 _sharePriceInitial = metaWallet.sharePrice();
        uint256 _totalAssetsBefore = metaWallet.totalAssets();

        _investInStrategy(15_000 * _1_USDC);

        assertEq(metaWallet.totalAssets(), _totalAssetsBefore);
        assertEq(metaWallet.sharePrice(), _sharePriceInitial);

        _divestFromStrategy();

        uint256 _actualIdle = metaWallet.totalIdle();
        bytes32 _merkleRoot = keccak256(abi.encodePacked("settled"));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_actualIdle, _merkleRoot);

        uint256 _aliceAssetsReceived = _redeemUserShares(users.alice, _aliceShares);
        uint256 _bobAssetsReceived = _redeemUserShares(users.bob, _bobShares);

        assertApproxEqRel(_aliceAssetsReceived, 10_000 * _1_USDC, 0.01e18);
        assertApproxEqRel(_bobAssetsReceived, 20_000 * _1_USDC, 0.01e18);

        assertEq(metaWallet.totalSupply(), 0);
    }

    /* ///////////////////////////////////////////////////////////////
                    HELPER FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function _setupUsersDeposits() internal {
        deal(USDC_MAINNET, users.alice, 10_000 * _1_USDC);
        deal(USDC_MAINNET, users.bob, 20_000 * _1_USDC);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(10_000 * _1_USDC, users.alice, users.alice);
        metaWallet.deposit(10_000 * _1_USDC, users.alice);
        vm.stopPrank();

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(20_000 * _1_USDC, users.bob, users.bob);
        metaWallet.deposit(20_000 * _1_USDC, users.bob);
        vm.stopPrank();
    }

    function _investInStrategy(uint256 _amount) internal {
        ERC4626ApproveAndDepositHook.ApproveAndDepositData memory _depositData =
            ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                vault: EXTERNAL_VAULT, assets: _amount, receiver: address(metaWallet), minShares: 0
            });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: DEPOSIT_HOOK_ID, data: abi.encode(_depositData) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    function _divestFromStrategy() internal {
        uint256 _externalShares = IERC4626(EXTERNAL_VAULT).balanceOf(address(metaWallet));

        ERC4626RedeemHook.RedeemData memory _redeemData = ERC4626RedeemHook.RedeemData({
            vault: EXTERNAL_VAULT,
            shares: _externalShares,
            receiver: address(metaWallet),
            owner: address(metaWallet),
            minAssets: 0
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: REDEEM_HOOK_ID, data: abi.encode(_redeemData) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    function _redeemUserShares(address _user, uint256 _shares) internal returns (uint256) {
        vm.startPrank(_user);
        metaWallet.requestRedeem(_shares, _user, _user);
        uint256 _assets = metaWallet.redeem(_shares, _user, _user);
        vm.stopPrank();
        return _assets;
    }

    /* ///////////////////////////////////////////////////////////////
                    SECTION 14: MAX ALLOWED DELTA TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_SetMaxAllowedDelta_Success() public {
        uint256 _maxDelta = 500; // 5% in BPS

        vm.prank(users.admin);
        metaWallet.setMaxAllowedDelta(_maxDelta);

        assertEq(metaWallet.maxAllowedDelta(), _maxDelta);
    }

    function test_SetMaxAllowedDelta_EmitsEvent() public {
        uint256 _maxDelta = 500; // 5%

        vm.prank(users.admin);
        vm.expectEmit(true, false, false, false);
        emit IVaultModule.MaxAllowedDeltaUpdated(_maxDelta);
        metaWallet.setMaxAllowedDelta(_maxDelta);
    }

    function testRevert_SetMaxAllowedDelta_Unauthorized() public {
        vm.prank(users.alice);
        vm.expectRevert();
        metaWallet.setMaxAllowedDelta(500);
    }

    function testRevert_SetMaxAllowedDelta_ExceedsBPS() public {
        vm.prank(users.admin);
        vm.expectRevert(bytes("MW4"));
        metaWallet.setMaxAllowedDelta(10_001); // > 100%
    }

    function test_Settlement_WithinDelta_Success() public {
        uint256 _depositAmount = 10_000 * _1_USDC;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        // Set max delta to 10%
        vm.prank(users.admin);
        metaWallet.setMaxAllowedDelta(1000); // 10% in BPS

        // Settle with 5% increase (within 10% limit)
        uint256 _newTotalAssets = _depositAmount + (_depositAmount * 5 / 100); // 10,500 USDC
        bytes32 _merkleRoot = keccak256(abi.encodePacked("yield"));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets);
    }

    function test_Settlement_WithinDelta_Decrease_Success() public {
        uint256 _depositAmount = 10_000 * _1_USDC;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        // Set max delta to 10%
        vm.prank(users.admin);
        metaWallet.setMaxAllowedDelta(1000); // 10% in BPS

        // Settle with 5% decrease (within 10% limit)
        uint256 _newTotalAssets = _depositAmount - (_depositAmount * 5 / 100); // 9,500 USDC
        bytes32 _merkleRoot = keccak256(abi.encodePacked("loss"));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets);
    }

    function testRevert_Settlement_ExceedsDelta_Increase() public {
        uint256 _depositAmount = 10_000 * _1_USDC;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        // Set max delta to 5%
        vm.prank(users.admin);
        metaWallet.setMaxAllowedDelta(500); // 5% in BPS

        // Try to settle with 10% increase (exceeds 5% limit)
        uint256 _newTotalAssets = _depositAmount + (_depositAmount * 10 / 100); // 11,000 USDC
        bytes32 _merkleRoot = keccak256(abi.encodePacked("big_yield"));

        vm.prank(users.executor);
        vm.expectRevert(bytes("MW3"));
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);
    }

    function testRevert_Settlement_ExceedsDelta_Decrease() public {
        uint256 _depositAmount = 10_000 * _1_USDC;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        // Set max delta to 5%
        vm.prank(users.admin);
        metaWallet.setMaxAllowedDelta(500); // 5% in BPS

        // Try to settle with 10% decrease (exceeds 5% limit)
        uint256 _newTotalAssets = _depositAmount - (_depositAmount * 10 / 100); // 9,000 USDC
        bytes32 _merkleRoot = keccak256(abi.encodePacked("big_loss"));

        vm.prank(users.executor);
        vm.expectRevert(bytes("MW3"));
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);
    }

    function test_Settlement_DeltaDisabled_NoRestriction() public {
        uint256 _depositAmount = 10_000 * _1_USDC;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        // maxAllowedDelta is 0 by default (disabled)
        assertEq(metaWallet.maxAllowedDelta(), 0);

        // Settle with 50% increase (would fail if delta was enforced)
        uint256 _newTotalAssets = _depositAmount + (_depositAmount * 50 / 100); // 15,000 USDC
        bytes32 _merkleRoot = keccak256(abi.encodePacked("huge_yield"));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets);
    }

    function test_Settlement_ZeroTotalAssets_NoDeltaCheck() public {
        // Set max delta to 1%
        vm.prank(users.admin);
        metaWallet.setMaxAllowedDelta(100); // 1% in BPS

        // totalAssets is 0, settle to any value (no delta check when current is 0)
        uint256 _newTotalAssets = 10_000 * _1_USDC;
        bytes32 _merkleRoot = keccak256(abi.encodePacked("initial"));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets);
    }

    function test_Settlement_ExactDelta_Success() public {
        uint256 _depositAmount = 10_000 * _1_USDC;
        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        // Set max delta to exactly 10%
        vm.prank(users.admin);
        metaWallet.setMaxAllowedDelta(1000); // 10% in BPS

        // Settle with exactly 10% increase (should succeed at boundary)
        uint256 _newTotalAssets = _depositAmount + (_depositAmount * 10 / 100); // 11,000 USDC
        bytes32 _merkleRoot = keccak256(abi.encodePacked("exact_yield"));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets);
    }
}
