// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { USDC_MAINNET, _1_USDC } from "metawallet/src/helpers/AddressBook.sol";
import { IMetaWallet } from "metawallet/src/interfaces/IMetaWallet.sol";
import { ERC4626, ERC7540 } from "metawallet/src/lib/ERC7540.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";
import { BaseTest } from "metawallet/test/base/BaseTest.t.sol";
import { ERC4626Events } from "metawallet/test/helpers/ERC4626Events.sol";
import { ERC7540Events } from "metawallet/test/helpers/ERC7540Events.sol";
import { ERC1967Factory } from "solady/utils/ERC1967Factory.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract ERC7540Test is BaseTest, ERC7540Events, ERC4626Events {
    using SafeTransferLib for address;

    IMetaWallet public metaWallet;
    ERC1967Factory public proxyFactory;

    function setUp() public {
        _setUp("MAINNET", 23_783_139);
        proxyFactory = new ERC1967Factory();
        MetaWallet metaWalletImplementation = new MetaWallet();
        bytes memory initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, makeAddr("registry"), "kam.metawallet.1.0"
        );
        address metaWalletProxy = proxyFactory.deployAndCall(address(metaWalletImplementation), users.admin, initData);
        MetaWallet(payable(metaWalletProxy)).grantRoles(users.admin, 1); // ADMIN ROLE
        VaultModule vault = new VaultModule();
        bytes4[] memory vaultSelectors = vault.selectors();
        vm.startPrank(users.admin);
        MetaWallet(payable(metaWalletProxy)).addFunctions(vaultSelectors, address(vault), false);
        VaultModule(metaWalletProxy).initializeVault(USDC_MAINNET, "Meta USDC", "mUSDC");
        metaWallet = IMetaWallet(metaWalletProxy);
        vm.stopPrank();

        vm.startPrank(users.alice);
        USDC_MAINNET.safeApprove(address(metaWallet), type(uint256).max);
    }

    function test_erc7540_requestDeposit() public {
        vm.startPrank(users.alice);
        uint256 amount = 100 * _1_USDC;
        vm.expectEmit();
        emit DepositRequest(users.alice, users.alice, 0, users.alice, amount);
        metaWallet.requestDeposit(amount, users.alice, users.alice);
        assertEq(USDC_MAINNET.balanceOf(address(metaWallet)), amount);
        assertEq(metaWallet.claimableDepositRequest(users.alice), 100 * _1_USDC);
        assertEq(metaWallet.pendingDepositRequest(users.alice), 0);
        assertEq(metaWallet.totalAssets(), 0);
        assertEq(metaWallet.balanceOf(users.alice), 0);
    }

    function test_revert_erc7540_requestDeposit_zeroAssets() public {
        vm.expectRevert(ERC7540.InvalidZeroAssets.selector);
        metaWallet.requestDeposit(0, users.alice, users.alice);
    }

    function test_erc7540_deposit() public {
        uint256 amount = 100 * _1_USDC;
        metaWallet.requestDeposit(amount, users.alice, users.alice);

        vm.expectEmit();
        emit Deposit(users.alice, users.alice, amount, amount);
        uint256 shares = metaWallet.deposit(amount, users.alice);
        assertEq(USDC_MAINNET.balanceOf(address(metaWallet)), amount);
        assertEq(metaWallet.claimableDepositRequest(users.alice), 0);
        assertEq(metaWallet.pendingDepositRequest(users.alice), 0);
        assertEq(metaWallet.totalAssets(), amount);
        assertEq(shares, amount);
        assertEq(metaWallet.balanceOf(users.alice), shares);
    }

    function test_revert_erc7540_deposit_noRequest() public {
        uint256 amount = 100 * _1_USDC;
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        metaWallet.deposit(amount, users.alice);
    }

    function test_erc7540_mint() public {
        uint256 amount = 100 * _1_USDC;

        metaWallet.requestDeposit(amount, users.alice, users.alice);

        vm.expectEmit();
        emit Deposit(users.alice, users.alice, amount, amount);
        uint256 assets = metaWallet.mint(amount, users.alice);
        assertEq(USDC_MAINNET.balanceOf(address(metaWallet)), amount);
        assertEq(metaWallet.claimableDepositRequest(users.alice), 0);
        assertEq(metaWallet.pendingDepositRequest(users.alice), 0);
        assertEq(metaWallet.totalAssets(), amount, "1");
        assertEq(assets, amount, "2");
        assertEq(metaWallet.balanceOf(users.alice), assets, "3");
    }

    function test_revert_erc7540_mint_noRequest() public {
        uint256 amount = 100 * _1_USDC;
        vm.expectRevert(ERC4626.MintMoreThanMax.selector);
        metaWallet.mint(amount, users.alice);
    }

    function test_erc7540_requestRedeem() public {
        uint256 amount = 100 * _1_USDC;
        metaWallet.requestDeposit(amount, users.alice, users.alice);
        uint256 shares = metaWallet.deposit(amount, users.alice);
        uint256 sharePriceBefore = metaWallet.sharePrice();
        vm.expectEmit();
        emit RedeemRequest(users.alice, users.alice, 0, users.alice, shares);

        // Request should be fulfilled automatically
        metaWallet.requestRedeem(shares, users.alice, users.alice);
        uint256 sharePriceAfter = metaWallet.sharePrice();
        assertEq(sharePriceAfter, sharePriceBefore);

        assertEq(metaWallet.balanceOf(address(metaWallet)), shares);
        assertEq(metaWallet.balanceOf(users.alice), 0);
        assertEq(metaWallet.claimableRedeemRequest(users.alice), amount);
        assertEq(metaWallet.pendingRedeemRequest(users.alice), 0);
        assertEq(metaWallet.totalSupply(), amount);
        assertEq(metaWallet.totalAssets(), amount);
    }

    function test_revert_erc7540_requestRedeem_zeroShares() public {
        vm.expectRevert(ERC7540.InvalidZeroShares.selector);
        metaWallet.requestRedeem(0, users.alice, users.alice);
    }

    function test_erc7540_redeem() public {
        uint256 amount = 100 * _1_USDC;
        test_erc7540_requestRedeem();

        uint256 sharePriceBefore = metaWallet.sharePrice();
        uint256 balanceBefore = USDC_MAINNET.balanceOf(users.alice);
        vm.expectEmit();
        emit Withdraw(users.alice, users.alice, users.alice, amount, amount);
        uint256 assets = metaWallet.redeem(amount, users.alice, users.alice);
        uint256 sharePriceAfter = metaWallet.sharePrice();
        assertEq(sharePriceAfter, sharePriceBefore);
        uint256 balanceAfter = USDC_MAINNET.balanceOf(users.alice);
        assertEq(assets, amount);
        assertEq(balanceAfter - balanceBefore, amount);
        assertEq(metaWallet.pendingRedeemRequest(users.alice), 0);
        assertEq(metaWallet.claimableRedeemRequest(users.alice), 0);
        assertEq(metaWallet.totalSupply(), 0);
        assertEq(metaWallet.totalAssets(), 0);
    }

    function test_revert_erc7540_redeem_noRequest() public {
        uint256 amount = 100 * _1_USDC;
        metaWallet.requestDeposit(amount, users.alice, users.alice);
        uint256 shares = metaWallet.deposit(amount, users.alice);

        vm.expectRevert(ERC4626.RedeemMoreThanMax.selector);
        metaWallet.redeem(shares, users.alice, users.alice);
    }

    function test_erc7540_withdraw() public {
        uint256 amount = 100 * _1_USDC;
        metaWallet.requestDeposit(amount, users.alice, users.alice);
        uint256 shares = metaWallet.deposit(amount, users.alice);
        shares;

        metaWallet.requestRedeem(shares, users.alice, users.alice);

        uint256 balanceBefore = USDC_MAINNET.balanceOf(users.alice);
        vm.expectEmit();
        emit Withdraw(users.alice, users.alice, users.alice, amount, shares);
        uint256 burntShares = metaWallet.withdraw(amount, users.alice, users.alice);
        uint256 balanceAfter = USDC_MAINNET.balanceOf(users.alice);
        assertEq(burntShares, shares);
        assertEq(balanceAfter - balanceBefore, amount);
        assertEq(metaWallet.pendingRedeemRequest(users.alice), 0);
        assertEq(metaWallet.claimableRedeemRequest(users.alice), 0);
        assertEq(metaWallet.totalSupply(), 0);
        assertEq(metaWallet.totalAssets(), 0);
    }

    function test_revert_erc7540_withdraw_noRequest() public {
        uint256 amount = 100 * _1_USDC;

        vm.expectRevert(ERC4626.WithdrawMoreThanMax.selector);
        metaWallet.withdraw(amount, users.alice, users.alice);
    }
}
