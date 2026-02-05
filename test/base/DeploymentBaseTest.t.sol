// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { BaseTest } from "./BaseTest.t.sol";

// Protocol contracts
import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

// External dependencies
import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";
import { MinimalUUPSFactory } from "minimal-uups-factory/MinimalUUPSFactory.sol";

// Mock contracts
import { MockRegistry } from "metawallet/test/helpers/mocks/MockRegistry.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

// Test utilities
import { Utilities } from "metawallet/test/utils/Utilities.sol";

/// @title TestMockERC20 for testing
contract TestMockERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title WalletDeployment - Struct to hold deployed wallet contracts
struct WalletDeployment {
    string id;
    TestMockERC20 asset;
    MetaWallet proxy;
    ERC4626ApproveAndDepositHook depositHook;
    ERC4626RedeemHook redeemHook;
    OneInchSwapHook oneInchSwapHook;
}

/// @title DeploymentBaseTest
/// @notice Base test contract that deploys the full MetaWallet protocol with multi-wallet support
/// @dev Uses the same deployment flow as 07_DeployMultiWallet.s.sol for consistency
contract DeploymentBaseTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 constant ADMIN_ROLE = 1; // _ROLE_0
    uint256 constant EXECUTOR_ROLE = 2; // _ROLE_1

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED PROTOCOL CONTRACTS
    // ═══════════════════════════════════════════════════════════════════════════

    MetaWallet public implementation;
    VaultModule public vaultModule;
    MinimalUUPSFactory public factory;
    MockRegistry public registry;

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTI-WALLET DEPLOYMENTS
    // ═══════════════════════════════════════════════════════════════════════════

    WalletDeployment public usdcWallet;
    WalletDeployment public wbtcWallet;

    // Legacy compatibility - points to USDC wallet by default
    MetaWallet public metaWallet;
    TestMockERC20 public asset;
    ERC4626ApproveAndDepositHook public depositHook;
    ERC4626RedeemHook public redeemHook;
    OneInchSwapHook public oneInchSwapHook;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public usdcSalt = bytes32(uint256(1));
    bytes32 public wbtcSalt = bytes32(uint256(2));

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Setup base test utilities and users
        utils = new Utilities();
        users = Users({
            owner: utils.createUser("Owner", new address[](0)),
            admin: utils.createUser("Admin", new address[](0)),
            executor: utils.createUser("Executor", new address[](0)),
            alice: utils.createUser("Alice", new address[](0)),
            bob: utils.createUser("Bob", new address[](0)),
            charlie: utils.createUser("Charlie", new address[](0))
        });

        // Deploy full protocol with multiple wallets
        _deployMultiWalletProtocol();

        // Set legacy compatibility references (point to USDC wallet)
        metaWallet = usdcWallet.proxy;
        asset = usdcWallet.asset;
        depositHook = usdcWallet.depositHook;
        redeemHook = usdcWallet.redeemHook;
        oneInchSwapHook = usdcWallet.oneInchSwapHook;
    }

    /// @notice Deploys the full MetaWallet protocol with multiple wallets
    /// @dev Mirrors the deployment flow from 07_DeployMultiWallet.s.sol
    function _deployMultiWalletProtocol() internal {
        vm.startPrank(users.owner);

        // Step 1: Deploy shared infrastructure
        _deploySharedInfrastructure();

        // Step 2: Deploy USDC wallet
        usdcWallet = _deployWallet("usdc", "Meta Vault USDC", "mwUSDC", 6, usdcSalt);

        // Step 3: Deploy WBTC wallet
        wbtcWallet = _deployWallet("wbtc", "Meta Vault WBTC", "mwBTC", 8, wbtcSalt);

        vm.stopPrank();
    }

    /// @notice Deploys shared infrastructure (implementation, vaultModule, factory, registry)
    function _deploySharedInfrastructure() internal {
        // Deploy mock registry
        registry = new MockRegistry();

        // Deploy factory
        factory = new MinimalUUPSFactory();

        // Deploy implementation
        implementation = new MetaWallet();

        // Deploy VaultModule
        vaultModule = new VaultModule();
    }

    /// @notice Deploys a single wallet with all its components
    /// @param id Wallet identifier (e.g., "usdc", "wbtc")
    /// @param vaultName Name for the vault token
    /// @param vaultSymbol Symbol for the vault token
    /// @param decimals Decimals for the mock asset
    /// @param salt Salt for deterministic deployment
    function _deployWallet(
        string memory id,
        string memory vaultName,
        string memory vaultSymbol,
        uint8 decimals,
        bytes32 salt
    )
        internal
        returns (WalletDeployment memory wallet)
    {
        wallet.id = id;

        // Deploy mock asset
        string memory assetName = string.concat("Mock ", vaultSymbol);
        string memory assetSymbol = string.concat("m", vaultSymbol);
        wallet.asset = new TestMockERC20(assetName, assetSymbol, decimals);

        // Mint tokens to test users
        wallet.asset.mint(users.owner, 1_000_000 * (10 ** decimals));
        wallet.asset.mint(users.alice, 1_000_000 * (10 ** decimals));
        wallet.asset.mint(users.bob, 1_000_000 * (10 ** decimals));
        wallet.asset.mint(users.charlie, 1_000_000 * (10 ** decimals));

        // Deploy proxy via factory
        bytes32 fullSalt =
            bytes32(uint256(uint160(address(users.owner))) << 96) | (salt & bytes32(uint256(type(uint96).max)));

        address predictedAddress = factory.predictDeterministicAddress(address(implementation), fullSalt);

        bytes memory initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, IRegistry(address(registry)), id
        );

        address proxy = factory.deployDeterministicAndCall(address(implementation), fullSalt, initData);

        require(proxy == predictedAddress, "Address mismatch!");
        wallet.proxy = MetaWallet(payable(proxy));

        // Setup VaultModule
        wallet.proxy.grantRoles(users.owner, ADMIN_ROLE);
        bytes4[] memory vaultSelectors = vaultModule.selectors();
        wallet.proxy.addFunctions(vaultSelectors, address(vaultModule), false);
        VaultModule(address(wallet.proxy)).initializeVault(address(wallet.asset), vaultName, vaultSymbol);

        // Deploy and install ERC4626 hooks
        wallet.depositHook = new ERC4626ApproveAndDepositHook(address(wallet.proxy));
        wallet.redeemHook = new ERC4626RedeemHook(address(wallet.proxy));

        wallet.proxy.installHook(keccak256("hook.erc4626.deposit"), address(wallet.depositHook));
        wallet.proxy.installHook(keccak256("hook.erc4626.redeem"), address(wallet.redeemHook));

        // Deploy 1inch swap hook
        wallet.oneInchSwapHook = new OneInchSwapHook(address(wallet.proxy));
        wallet.proxy.installHook(keccak256("hook.1inch.swap"), address(wallet.oneInchSwapHook));

        return wallet;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - USDC WALLET (DEFAULT)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Helper to get the VaultModule interface on the default (USDC) proxy
    function vault() internal view returns (VaultModule) {
        return VaultModule(address(metaWallet));
    }

    /// @notice Helper to approve and deposit assets to default wallet
    function _depositAssets(address user, uint256 amount) internal returns (uint256 shares) {
        return _depositAssetsTo(usdcWallet, user, amount);
    }

    /// @notice Helper to redeem shares from default wallet
    function _redeemShares(address user, uint256 shares) internal returns (uint256 assets) {
        return _redeemSharesFrom(usdcWallet, user, shares);
    }

    /// @notice Helper to get user's share balance in default wallet
    function _getShares(address user) internal view returns (uint256) {
        return _getSharesFrom(usdcWallet, user);
    }

    /// @notice Helper to get user's asset balance for default wallet
    function _getAssetBalance(address user) internal view returns (uint256) {
        return _getAssetBalanceFrom(usdcWallet, user);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - MULTI-WALLET
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Helper to get the VaultModule interface for a specific wallet
    function vaultFor(WalletDeployment storage wallet) internal view returns (VaultModule) {
        return VaultModule(address(wallet.proxy));
    }

    /// @notice Helper to approve and deposit assets to a specific wallet
    function _depositAssetsTo(
        WalletDeployment storage wallet,
        address user,
        uint256 amount
    )
        internal
        returns (uint256 shares)
    {
        vm.startPrank(user);
        wallet.asset.approve(address(wallet.proxy), amount);
        shares = VaultModule(address(wallet.proxy)).deposit(amount, user);
        vm.stopPrank();
    }

    /// @notice Helper to redeem shares from a specific wallet
    function _redeemSharesFrom(
        WalletDeployment storage wallet,
        address user,
        uint256 shares
    )
        internal
        returns (uint256 assets)
    {
        vm.startPrank(user);
        assets = VaultModule(address(wallet.proxy)).redeem(shares, user, user);
        vm.stopPrank();
    }

    /// @notice Helper to get user's share balance in a specific wallet
    function _getSharesFrom(WalletDeployment storage wallet, address user) internal view returns (uint256) {
        return VaultModule(address(wallet.proxy)).balanceOf(user);
    }

    /// @notice Helper to get user's asset balance for a specific wallet
    function _getAssetBalanceFrom(WalletDeployment storage wallet, address user) internal view returns (uint256) {
        return wallet.asset.balanceOf(user);
    }
}
