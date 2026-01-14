// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";

import { MetaWallet } from "metawallet/src/MetaWallet.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { MinimalSmartAccountFactory } from "minimal-smart-account/MinimalSmartAccountFactory.sol";
import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";

import { MockERC20, MockRegistry } from "../helpers/MockContracts.sol";
import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployMultiWalletScript
/// @notice Deploys multiple MetaWallet proxies (USDC, WBTC, etc.) with shared infrastructure
/// @dev Reads from deployments/config/{network}.json and writes to deployments/output/{network}/wallets.json
contract DeployMultiWalletScript is Script, DeploymentManager {
    /// @notice Deploy all wallets from config
    function run() external {
        // Read configuration
        MultiWalletConfig memory config = readMultiWalletConfig();
        logMultiWalletConfig(config);
        validateMultiWalletConfig(config);

        // Read existing output (if any)
        MultiWalletOutput memory output = readMultiWalletOutput();

        vm.startBroadcast();

        // Step 1: Deploy shared infrastructure (implementation, vaultModule)
        _deploySharedInfrastructure(config, output);

        // Step 2: Handle mock assets or use real assets
        address factory = config.shared.factory;
        address registry = config.shared.registry;

        if (config.deployment.deployMockAssets) {
            (factory, registry) = _deployOrReuseSharedMocks(config, output);
        } else {
            require(factory != address(0), "Missing factory address in config");
            require(registry != address(0), "Missing registry address in config");
        }

        // Step 3: Deploy each wallet
        output.wallets = new WalletDeployment[](config.wallets.length);

        for (uint256 i = 0; i < config.wallets.length; i++) {
            _log(string.concat("\n=== Deploying Wallet: ", config.wallets[i].id, " ==="));
            output.wallets[i] = _deployWallet(config.wallets[i], config, output.shared, factory, registry);
        }

        vm.stopBroadcast();

        // Write output
        writeMultiWalletOutput(output);

        // Print summary
        _printSummary(output);
    }

    /// @dev Deploy shared implementation and vaultModule if not already deployed
    function _deploySharedInfrastructure(MultiWalletConfig memory, MultiWalletOutput memory output) internal {
        // Check if implementation already exists and has code
        if (output.shared.implementation != address(0) && output.shared.implementation.code.length > 0) {
            _log("[SHARED] Using existing implementation:", output.shared.implementation);
        } else {
            output.shared.implementation = address(new MetaWallet());
            _log("[SHARED] MetaWallet implementation deployed:", output.shared.implementation);
        }

        // Check if vaultModule already exists and has code
        if (output.shared.vaultModule != address(0) && output.shared.vaultModule.code.length > 0) {
            _log("[SHARED] Using existing VaultModule:", output.shared.vaultModule);
        } else {
            output.shared.vaultModule = address(new VaultModule());
            _log("[SHARED] VaultModule deployed:", output.shared.vaultModule);
        }
    }

    /// @dev Deploy or reuse shared mock factory and registry
    function _deployOrReuseSharedMocks(
        MultiWalletConfig memory,
        MultiWalletOutput memory output
    )
        internal
        returns (address factory, address registry)
    {
        // Check if mock factory already exists
        if (output.shared.mockFactory != address(0) && output.shared.mockFactory.code.length > 0) {
            factory = output.shared.mockFactory;
            _log("[SHARED] Using existing mock factory:", factory);
        } else {
            MinimalSmartAccountFactory mockFactory = new MinimalSmartAccountFactory();
            factory = address(mockFactory);
            output.shared.mockFactory = factory;
            _log("[SHARED] Mock factory deployed:", factory);
        }

        // Check if mock registry already exists
        if (output.shared.mockRegistry != address(0) && output.shared.mockRegistry.code.length > 0) {
            registry = output.shared.mockRegistry;
            _log("[SHARED] Using existing mock registry:", registry);
        } else {
            MockRegistry mockRegistry = new MockRegistry();
            registry = address(mockRegistry);
            output.shared.mockRegistry = registry;
            _log("[SHARED] Mock registry deployed:", registry);
        }

        return (factory, registry);
    }

    /// @dev Deploy a single wallet with all its components
    function _deployWallet(
        WalletConfig memory walletConfig,
        MultiWalletConfig memory config,
        SharedContractAddresses memory shared,
        address factory,
        address registry
    )
        internal
        returns (WalletDeployment memory wallet)
    {
        wallet.id = walletConfig.id;

        // Step 1: Handle asset (mock or real)
        if (config.deployment.deployMockAssets) {
            // Deploy mock asset for this wallet
            string memory mockName = string.concat("Mock ", walletConfig.vault.symbol);
            string memory mockSymbol = string.concat("m", walletConfig.vault.symbol);
            uint8 decimals = _strEq(walletConfig.id, "usdc") ? 6 : 8; // USDC has 6 decimals, WBTC has 8

            MockERC20 mockAsset = new MockERC20(mockName, mockSymbol, decimals);
            wallet.asset = address(mockAsset);
            wallet.mockAsset = address(mockAsset);

            // Mint some tokens to owner for testing
            mockAsset.mint(config.roles.owner, 1_000_000 * (10 ** decimals));
            _log("Mock asset deployed:", wallet.asset);
        } else {
            require(walletConfig.asset != address(0), string.concat("Missing asset for wallet: ", walletConfig.id));
            wallet.asset = walletConfig.asset;
            _log("Using real asset:", wallet.asset);
        }

        // Step 2: Deploy proxy with deterministic address
        wallet.proxy = _deployProxy(walletConfig, config, shared, factory, registry, wallet.asset);

        // Step 3: Setup VaultModule and hooks
        _setupVaultAndHooks(wallet, walletConfig, shared);

        return wallet;
    }

    /// @dev Deploy proxy with CREATE2 for deterministic address
    function _deployProxy(
        WalletConfig memory walletConfig,
        MultiWalletConfig memory config,
        SharedContractAddresses memory shared,
        address factory,
        address registry,
        address
    )
        internal
        returns (address proxy)
    {
        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt =
            bytes32(uint256(uint160(msg.sender)) << 96) | (walletConfig.salt & bytes32(uint256(type(uint96).max)));

        MinimalSmartAccountFactory factoryContract = MinimalSmartAccountFactory(factory);
        address predictedAddress = factoryContract.predictDeterministicAddress(fullSalt);
        _log("Predicted proxy address:", predictedAddress);

        proxy = factoryContract.deployDeterministic(
            shared.implementation, fullSalt, config.roles.owner, IRegistry(registry), walletConfig.id
        );
        _log("Proxy deployed:", proxy);

        require(proxy == predictedAddress, "Address mismatch!");
        return proxy;
    }

    /// @dev Setup VaultModule and install hooks
    function _setupVaultAndHooks(
        WalletDeployment memory wallet,
        WalletConfig memory walletConfig,
        SharedContractAddresses memory shared
    )
        internal
    {
        MetaWallet metaWallet = MetaWallet(payable(wallet.proxy));

        // Grant ADMIN_ROLE to deployer
        metaWallet.grantRoles(msg.sender, 1); // ADMIN_ROLE = 1
        _log("ADMIN_ROLE granted to deployer");

        // Setup VaultModule
        bytes4[] memory vaultSelectors = VaultModule(shared.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, shared.vaultModule, false);
        VaultModule(wallet.proxy).initializeVault(wallet.asset, walletConfig.vault.name, walletConfig.vault.symbol);
        _log("VaultModule initialized");

        // Deploy and install ERC4626 hooks (unique per proxy)
        wallet.depositHook = address(new ERC4626ApproveAndDepositHook(wallet.proxy));
        wallet.redeemHook = address(new ERC4626RedeemHook(wallet.proxy));

        metaWallet.installHook(keccak256("hook.erc4626.deposit"), wallet.depositHook);
        metaWallet.installHook(keccak256("hook.erc4626.redeem"), wallet.redeemHook);
        _log("ERC4626 hooks deployed and installed");

        // Deploy 1inch swap hook (unique per proxy)
        wallet.oneInchSwapHook = address(new OneInchSwapHook(wallet.proxy));
        metaWallet.installHook(keccak256("hook.1inch.swap"), wallet.oneInchSwapHook);
        _log("1inch swap hook deployed and installed");
    }

    /// @dev Print deployment summary
    function _printSummary(MultiWalletOutput memory output) internal view {
        _log("\n========================================");
        _log("     MULTI-WALLET DEPLOYMENT COMPLETE");
        _log("========================================");
        _log("Implementation:  ", output.shared.implementation);
        _log("VaultModule:     ", output.shared.vaultModule);

        if (output.shared.mockFactory != address(0)) {
            _log("Mock Factory:    ", output.shared.mockFactory);
            _log("Mock Registry:   ", output.shared.mockRegistry);
        }

        for (uint256 i = 0; i < output.wallets.length; i++) {
            _log(string.concat("\n--- ", output.wallets[i].id, " ---"));
            _log("Asset:           ", output.wallets[i].asset);
            _log("Proxy:           ", output.wallets[i].proxy);
            _log("Deposit Hook:    ", output.wallets[i].depositHook);
            _log("Redeem Hook:     ", output.wallets[i].redeemHook);
            _log("1inch Swap Hook: ", output.wallets[i].oneInchSwapHook);
        }

        _log("\n========================================");
    }
}
