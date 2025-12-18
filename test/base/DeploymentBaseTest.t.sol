// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { BaseTest } from "./BaseTest.t.sol";

// Protocol contracts
import { MetaWallet } from "metawallet/src/MetaWallet.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

// External dependencies
import { MinimalSmartAccountFactory } from "minimal-smart-account/MinimalSmartAccountFactory.sol";
import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";

// Mock contracts
import { MockRegistry } from "metawallet/test/helpers/mocks/MockRegistry.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

// Test utilities
import { Utilities } from "metawallet/test/utils/Utilities.sol";

/// @title MockERC20 for testing
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

/// @title DeploymentBaseTest
/// @notice Base test contract that deploys the full MetaWallet protocol
/// @dev Uses the same deployment flow as production scripts for consistency
contract DeploymentBaseTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 constant ADMIN_ROLE = 1; // _ROLE_0
    uint256 constant EXECUTOR_ROLE = 2; // _ROLE_1

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONTRACTS
    // ═══════════════════════════════════════════════════════════════════════════

    // Core
    MetaWallet public implementation;
    VaultModule public vaultModule;
    MetaWallet public metaWallet; // Proxy instance

    // Hooks
    ERC4626ApproveAndDepositHook public depositHook;
    ERC4626RedeemHook public redeemHook;
    OneInchSwapHook public oneInchSwapHook;

    // External dependencies
    MinimalSmartAccountFactory public factory;
    MockRegistry public registry;

    // Mock assets
    TestMockERC20 public asset;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    string public vaultName = "MetaVault Mock USDC";
    string public vaultSymbol = "mvmUSDC";
    string public accountId = "metawallet.test.v1";
    bytes32 public salt = bytes32(uint256(1));

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

        // Deploy full protocol
        _deployProtocol();
    }

    /// @notice Deploys the full MetaWallet protocol
    /// @dev Mirrors the deployment flow from Deploy.s.sol:DeployAll
    function _deployProtocol() internal {
        vm.startPrank(users.owner);

        // Step 0: Deploy mock dependencies
        _deployMocks();

        // Step 1: Deploy implementation
        implementation = new MetaWallet();

        // Step 2: Deploy VaultModule
        vaultModule = new VaultModule();

        // Step 3: Deploy proxy via factory
        bytes32 fullSalt =
            bytes32(uint256(uint160(address(users.owner))) << 96) | (salt & bytes32(uint256(type(uint96).max)));

        address predictedAddress = factory.predictDeterministicAddress(fullSalt);

        address proxy = factory.deployDeterministic(
            address(implementation), fullSalt, users.owner, IRegistry(address(registry)), accountId
        );

        require(proxy == predictedAddress, "Address mismatch!");
        metaWallet = MetaWallet(payable(proxy));

        // Step 4: Setup VaultModule
        metaWallet.grantRoles(users.owner, ADMIN_ROLE);
        bytes4[] memory vaultSelectors = vaultModule.selectors();
        metaWallet.addFunctions(vaultSelectors, address(vaultModule), false);
        VaultModule(address(metaWallet)).initializeVault(address(asset), vaultName, vaultSymbol);

        // Step 5: Deploy and install ERC4626 hooks
        depositHook = new ERC4626ApproveAndDepositHook(address(metaWallet));
        redeemHook = new ERC4626RedeemHook(address(metaWallet));

        metaWallet.installHook(keccak256("hook.erc4626.deposit"), address(depositHook));
        metaWallet.installHook(keccak256("hook.erc4626.redeem"), address(redeemHook));

        // Step 6: Deploy 1inch swap hook
        oneInchSwapHook = new OneInchSwapHook(address(metaWallet));
        metaWallet.installHook(keccak256("hook.1inch.swap"), address(oneInchSwapHook));

        vm.stopPrank();
    }

    /// @notice Deploys mock contracts for testing
    function _deployMocks() internal {
        // Deploy mock asset (USDC-like)
        asset = new TestMockERC20("Mock USDC", "mUSDC", 6);

        // Mint tokens to test users
        asset.mint(users.owner, 1_000_000 * 10 ** 6);
        asset.mint(users.alice, 1_000_000 * 10 ** 6);
        asset.mint(users.bob, 1_000_000 * 10 ** 6);
        asset.mint(users.charlie, 1_000_000 * 10 ** 6);

        // Deploy mock registry
        registry = new MockRegistry();

        // Deploy factory
        factory = new MinimalSmartAccountFactory();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Helper to get the VaultModule interface on the proxy
    function vault() internal view returns (VaultModule) {
        return VaultModule(address(metaWallet));
    }

    /// @notice Helper to approve and deposit assets
    function _depositAssets(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(metaWallet), amount);
        shares = vault().deposit(amount, user);
        vm.stopPrank();
    }

    /// @notice Helper to redeem shares
    function _redeemShares(address user, uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(user);
        assets = vault().redeem(shares, user, user);
        vm.stopPrank();
    }

    /// @notice Helper to get user's share balance
    function _getShares(address user) internal view returns (uint256) {
        return vault().balanceOf(user);
    }

    /// @notice Helper to get user's asset balance
    function _getAssetBalance(address user) internal view returns (uint256) {
        return asset.balanceOf(user);
    }
}
