// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MetaWallet } from "metawallet/src/MetaWallet.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { MinimalSmartAccountFactory } from "minimal-smart-account/MinimalSmartAccountFactory.sol";
import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";

import { DeploymentManager } from "./utils/DeploymentManager.sol";

// ═══════════════════════════════════════════════════════════════════════════════
// MOCK CONTRACTS FOR LOCAL TESTING
// ═══════════════════════════════════════════════════════════════════════════════

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @notice Mock ERC20 token for local testing
contract MockERC20 is ERC20 {
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

/// @notice Mock Registry for local testing
contract MockRegistry is IRegistry {
    mapping(address => mapping(address => mapping(bytes4 => bool))) public allowed;

    function authorizeAdapterCall(address, bytes4, bytes calldata) external pure override {
        // Always allow for testing
    }

    function isAdapterSelectorAllowed(address, address, bytes4) external pure override returns (bool) {
        return true; // Always allow for testing
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// DEPLOYMENT SCRIPTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @title DeployAll
/// @notice One-command deployment: implementation + proxy + VaultModule + hooks
/// @dev Uses JSON config files for deployment parameters
contract DeployAll is Script, DeploymentManager {
    struct DeployedContracts {
        address asset;
        address factory;
        address registry;
        address implementation;
        address vaultModule;
        address proxy;
        address depositHook;
        address redeemHook;
        address oneInchSwapHook;
    }

    function run() external {
        // Read network configuration from JSON
        NetworkConfig memory config = readNetworkConfig();
        logConfig(config);

        vm.startBroadcast();

        DeployedContracts memory deployed;
        deployed.asset = config.external_.asset;
        deployed.factory = config.external_.factory;
        deployed.registry = config.external_.registry;

        // Deploy mock assets if needed (localhost/testnet)
        if (config.deployment.deployMockAssets) {
            _deployMocks(deployed, config.roles.owner);
        }

        // Deploy core contracts
        _deployCore(deployed);

        // Deploy proxy
        _deployProxy(deployed, config);

        // Setup VaultModule and hooks
        _setupVaultAndHooks(deployed, config);

        vm.stopBroadcast();

        // Print summary
        _printSummary(deployed, config);
    }

    function _deployMocks(DeployedContracts memory deployed, address owner) internal {
        console.log("\n[0/6] Deploying mock assets for testing...");

        MockERC20 mockAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        deployed.asset = address(mockAsset);
        writeContractAddress("mockAsset", deployed.asset);
        console.log("Mock Asset deployed:", deployed.asset);

        mockAsset.mint(owner, 1_000_000 * 10 ** 6);

        MockRegistry mockRegistry = new MockRegistry();
        deployed.registry = address(mockRegistry);
        writeContractAddress("mockRegistry", deployed.registry);
        console.log("Mock Registry deployed:", deployed.registry);

        MinimalSmartAccountFactory mockFactory = new MinimalSmartAccountFactory();
        deployed.factory = address(mockFactory);
        writeContractAddress("mockFactory", deployed.factory);
        console.log("Mock Factory deployed:", deployed.factory);
    }

    function _deployCore(DeployedContracts memory deployed) internal {
        deployed.implementation = address(new MetaWallet());
        writeContractAddress("implementation", deployed.implementation);
        console.log("\n[1/6] MetaWallet implementation:", deployed.implementation);

        deployed.vaultModule = address(new VaultModule());
        writeContractAddress("vaultModule", deployed.vaultModule);
        console.log("[2/6] VaultModule:", deployed.vaultModule);
    }

    function _deployProxy(DeployedContracts memory deployed, NetworkConfig memory config) internal {
        // Salt format: [20 bytes caller address][12 bytes custom salt]
        // The factory checks that shr(96, salt) == caller
        bytes32 fullSalt = bytes32(uint256(uint160(msg.sender)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalSmartAccountFactory factoryContract = MinimalSmartAccountFactory(deployed.factory);
        address predictedAddress = factoryContract.predictDeterministicAddress(fullSalt);
        console.log("Predicted proxy address:", predictedAddress);

        string memory accountId = config.vault.accountId;
        deployed.proxy = factoryContract.deployDeterministic(
            deployed.implementation, msg.sender, fullSalt, config.roles.owner, IRegistry(deployed.registry), accountId
        );
        writeContractAddress("proxy", deployed.proxy);
        console.log("[3/6] Proxy deployed:", deployed.proxy);

        require(deployed.proxy == predictedAddress, "Address mismatch!");
    }

    function _setupVaultAndHooks(DeployedContracts memory deployed, NetworkConfig memory config) internal {
        MetaWallet metaWallet = MetaWallet(payable(deployed.proxy));

        // Grant ADMIN_ROLE (1 << 0 = 1) to the deployer so we can addFunctions
        // The owner can grant roles, and we ARE the owner during broadcast
        metaWallet.grantRoles(msg.sender, 1); // ADMIN_ROLE = 1
        console.log("ADMIN_ROLE granted to deployer");

        // Setup VaultModule
        bytes4[] memory vaultSelectors = VaultModule(deployed.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, deployed.vaultModule, false);
        VaultModule(deployed.proxy).initializeVault(deployed.asset, config.vault.name, config.vault.symbol);
        console.log("[4/6] VaultModule initialized");

        // Deploy and install ERC4626 hooks
        deployed.depositHook = address(new ERC4626ApproveAndDepositHook(deployed.proxy));
        deployed.redeemHook = address(new ERC4626RedeemHook(deployed.proxy));
        writeContractAddress("depositHook", deployed.depositHook);
        writeContractAddress("redeemHook", deployed.redeemHook);

        metaWallet.installHook(keccak256("hook.erc4626.deposit"), deployed.depositHook);
        metaWallet.installHook(keccak256("hook.erc4626.redeem"), deployed.redeemHook);
        console.log("[5/6] ERC4626 hooks deployed and installed");

        // Deploy 1inch swap hook
        deployed.oneInchSwapHook = address(new OneInchSwapHook(deployed.proxy));
        writeContractAddress("oneInchSwapHook", deployed.oneInchSwapHook);
        metaWallet.installHook(keccak256("hook.1inch.swap"), deployed.oneInchSwapHook);
        console.log("[6/6] 1inch swap hook deployed and installed");
    }

    function _printSummary(DeployedContracts memory deployed, NetworkConfig memory config) internal pure {
        console.log("\n========================================");
        console.log("       DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("Implementation:  ", deployed.implementation);
        console.log("VaultModule:     ", deployed.vaultModule);
        console.log("Proxy:           ", deployed.proxy);
        console.log("Deposit Hook:    ", deployed.depositHook);
        console.log("Redeem Hook:     ", deployed.redeemHook);
        console.log("1inch Swap Hook: ", deployed.oneInchSwapHook);
        console.log("----------------------------------------");
        console.log("Vault Name:      ", config.vault.name);
        console.log("Vault Symbol:    ", config.vault.symbol);
        console.log("Asset:           ", deployed.asset);
        console.log("========================================");
    }
}

/// @title Deploy
/// @notice Deployment script for MetaWallet implementation and VaultModule only
contract Deploy is Script, DeploymentManager {
    function run() external {
        NetworkConfig memory config = readNetworkConfig();
        logConfig(config);

        vm.startBroadcast();

        address implementation = address(new MetaWallet());
        writeContractAddress("implementation", implementation);
        console.log("MetaWallet implementation deployed at:", implementation);

        address vaultModule = address(new VaultModule());
        writeContractAddress("vaultModule", vaultModule);
        console.log("VaultModule deployed at:", vaultModule);

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Implementation:", implementation);
        console.log("VaultModule:", vaultModule);
    }
}

/// @title DeployProxy
/// @notice Deploys a MetaWallet proxy with VaultModule using the MinimalSmartAccountFactory
/// @dev Uses CREATE2 for deterministic addresses across chains
contract DeployProxy is Script, DeploymentManager {
    function run() external returns (address proxy) {
        NetworkConfig memory config = readNetworkConfig();
        DeploymentOutput memory existing = readDeploymentOutput();

        validateCoreDeployments(existing);
        logConfig(config);

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt = bytes32(uint256(uint160(msg.sender)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        console.log("Implementation:", existing.contracts.implementation);
        console.log("VaultModule:", existing.contracts.vaultModule);

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(config.external_.factory);

        address predictedAddress = factory.predictDeterministicAddress(fullSalt);
        console.log("Predicted proxy address:", predictedAddress);

        vm.startBroadcast();

        proxy = factory.deployDeterministic(
            existing.contracts.implementation,
            msg.sender,
            fullSalt,
            config.roles.owner,
            IRegistry(config.external_.registry),
            config.vault.accountId
        );
        writeContractAddress("proxy", proxy);
        console.log("Proxy deployed at:", proxy);

        // Setup VaultModule
        MetaWallet metaWallet = MetaWallet(payable(proxy));
        bytes4[] memory vaultSelectors = VaultModule(existing.contracts.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, existing.contracts.vaultModule, false);
        console.log("VaultModule functions added");

        VaultModule(proxy).initializeVault(config.external_.asset, config.vault.name, config.vault.symbol);
        console.log("Vault initialized with asset:", config.external_.asset);

        vm.stopBroadcast();

        require(proxy == predictedAddress, "Address mismatch!");

        console.log("\n=== Deployment Summary ===");
        console.log("Proxy:", proxy);
        console.log("Vault Name:", config.vault.name);
        console.log("Vault Symbol:", config.vault.symbol);
    }
}

/// @title DeployHooks
/// @notice Deploys hooks for an existing MetaWallet
contract DeployHooks is Script, DeploymentManager {
    function run() external {
        DeploymentOutput memory existing = readDeploymentOutput();
        require(existing.contracts.proxy != address(0), "Proxy not deployed");

        address proxy = existing.contracts.proxy;
        console.log("MetaWallet:", proxy);

        vm.startBroadcast();

        address depositHook = address(new ERC4626ApproveAndDepositHook(proxy));
        address redeemHook = address(new ERC4626RedeemHook(proxy));
        address oneInchSwapHook = address(new OneInchSwapHook(proxy));

        writeContractAddress("depositHook", depositHook);
        writeContractAddress("redeemHook", redeemHook);
        writeContractAddress("oneInchSwapHook", oneInchSwapHook);

        console.log("Deposit Hook deployed at:", depositHook);
        console.log("Redeem Hook deployed at:", redeemHook);
        console.log("1inch Swap Hook deployed at:", oneInchSwapHook);

        vm.stopBroadcast();
    }
}

/// @title InstallHooks
/// @notice Installs hooks on an existing MetaWallet
contract InstallHooks is Script, DeploymentManager {
    function run() external {
        DeploymentOutput memory existing = readDeploymentOutput();
        require(existing.contracts.proxy != address(0), "Proxy not deployed");
        require(existing.contracts.depositHook != address(0), "Deposit hook not deployed");
        require(existing.contracts.redeemHook != address(0), "Redeem hook not deployed");

        console.log("MetaWallet:", existing.contracts.proxy);

        vm.startBroadcast();

        MetaWallet metaWallet = MetaWallet(payable(existing.contracts.proxy));

        bytes32 depositHookId = keccak256("hook.erc4626.deposit");
        bytes32 redeemHookId = keccak256("hook.erc4626.redeem");

        metaWallet.installHook(depositHookId, existing.contracts.depositHook);
        metaWallet.installHook(redeemHookId, existing.contracts.redeemHook);

        if (existing.contracts.oneInchSwapHook != address(0)) {
            bytes32 oneInchHookId = keccak256("hook.1inch.swap");
            metaWallet.installHook(oneInchHookId, existing.contracts.oneInchSwapHook);
        }

        console.log("Hooks installed successfully");

        vm.stopBroadcast();
    }
}

/// @title PredictProxyAddress
/// @notice Predicts the MetaWallet proxy address without deploying
contract PredictProxyAddress is Script, DeploymentManager {
    function run() external view {
        NetworkConfig memory config = readNetworkConfig();

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt = bytes32(uint256(uint160(config.roles.deployer)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(config.external_.factory);
        address predictedAddress = factory.predictDeterministicAddress(fullSalt);

        console.log("Factory:", config.external_.factory);
        console.log("Deployer:", config.roles.deployer);
        console.log("Salt:", vm.toString(config.deployment.salt));
        console.log("Predicted proxy address:", predictedAddress);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MULTI-CHAIN DEPLOYMENT SCRIPTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @title DeployMultiChain
/// @notice Deploys MetaWallet to the current chain using production.json config
/// @dev This script is called by the shell script for each chain in sequence
///      All chains get the same proxy address via CREATE2
contract DeployMultiChain is Script, DeploymentManager {
    struct DeployedContracts {
        address asset;
        address factory;
        address registry;
        address implementation;
        address vaultModule;
        address proxy;
        address depositHook;
        address redeemHook;
        address oneInchSwapHook;
        string vaultName;
        string vaultSymbol;
    }

    function run() external {
        // Read production configuration
        MultiChainConfig memory config = readMainnetConfig();
        logMultiChainConfig(config);

        // Validate config
        validateProductionConfig(config);

        vm.startBroadcast();

        DeployedContracts memory deployed;
        deployed.asset = config.external_.asset;
        deployed.factory = config.external_.factory;
        deployed.registry = config.external_.registry;

        // Derive vault name and symbol from asset
        (deployed.vaultName, deployed.vaultSymbol) = _deriveVaultNameAndSymbol(deployed.asset, config);

        // Deploy core contracts
        _deployCore(deployed);

        // Deploy proxy with deterministic address
        _deployProxy(deployed, config);

        // Setup VaultModule and hooks
        _setupVaultAndHooks(deployed, config);

        vm.stopBroadcast();

        // Print summary
        _printSummary(deployed, config);
    }

    function _deriveVaultNameAndSymbol(
        address asset,
        MultiChainConfig memory config
    ) internal view returns (string memory name, string memory symbol) {
        // Get asset name and symbol
        string memory assetName;
        string memory assetSymbol;

        try ERC20(asset).name() returns (string memory n) {
            assetName = n;
        } catch {
            assetName = "Unknown";
        }

        try ERC20(asset).symbol() returns (string memory s) {
            assetSymbol = s;
        } catch {
            assetSymbol = "???";
        }

        // Derive vault name: "{namePrefix} {assetName}" e.g. "MetaVault USDC"
        name = string.concat(config.vault.namePrefix, " ", assetName);

        // Derive vault symbol: "{symbolPrefix}{assetSymbol}" e.g. "mvUSDC"
        symbol = string.concat(config.vault.symbolPrefix, assetSymbol);

        return (name, symbol);
    }

    function _deployCore(DeployedContracts memory deployed) internal {
        deployed.implementation = address(new MetaWallet());
        writeContractAddress("implementation", deployed.implementation);
        console.log("[1/6] MetaWallet implementation:", deployed.implementation);

        deployed.vaultModule = address(new VaultModule());
        writeContractAddress("vaultModule", deployed.vaultModule);
        console.log("[2/6] VaultModule:", deployed.vaultModule);
    }

    function _deployProxy(DeployedContracts memory deployed, MultiChainConfig memory config) internal {
        // Salt format: [20 bytes caller address][12 bytes custom salt]
        // This ensures the same address across all chains when using the same deployer + salt
        bytes32 fullSalt = bytes32(uint256(uint160(msg.sender)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalSmartAccountFactory factoryContract = MinimalSmartAccountFactory(deployed.factory);
        address predictedAddress = factoryContract.predictDeterministicAddress(fullSalt);
        console.log("Predicted proxy address:", predictedAddress);

        string memory accountId = config.vault.accountId;
        deployed.proxy = factoryContract.deployDeterministic(
            deployed.implementation, msg.sender, fullSalt, config.roles.owner, IRegistry(deployed.registry), accountId
        );
        writeContractAddress("proxy", deployed.proxy);
        console.log("[3/6] Proxy deployed:", deployed.proxy);

        require(deployed.proxy == predictedAddress, "Address mismatch!");
    }

    function _setupVaultAndHooks(DeployedContracts memory deployed, MultiChainConfig memory config) internal {
        MetaWallet metaWallet = MetaWallet(payable(deployed.proxy));

        // Grant ADMIN_ROLE to deployer
        metaWallet.grantRoles(msg.sender, 1); // ADMIN_ROLE = 1
        console.log("ADMIN_ROLE granted to deployer");

        // Setup VaultModule with derived name/symbol
        bytes4[] memory vaultSelectors = VaultModule(deployed.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, deployed.vaultModule, false);
        VaultModule(deployed.proxy).initializeVault(deployed.asset, deployed.vaultName, deployed.vaultSymbol);
        console.log("[4/6] VaultModule initialized");
        console.log("  Vault Name:", deployed.vaultName);
        console.log("  Vault Symbol:", deployed.vaultSymbol);

        // Deploy and install ERC4626 hooks
        deployed.depositHook = address(new ERC4626ApproveAndDepositHook(deployed.proxy));
        deployed.redeemHook = address(new ERC4626RedeemHook(deployed.proxy));
        writeContractAddress("depositHook", deployed.depositHook);
        writeContractAddress("redeemHook", deployed.redeemHook);

        metaWallet.installHook(keccak256("hook.erc4626.deposit"), deployed.depositHook);
        metaWallet.installHook(keccak256("hook.erc4626.redeem"), deployed.redeemHook);
        console.log("[5/6] ERC4626 hooks deployed and installed");

        // Deploy 1inch swap hook
        deployed.oneInchSwapHook = address(new OneInchSwapHook(deployed.proxy));
        writeContractAddress("oneInchSwapHook", deployed.oneInchSwapHook);
        metaWallet.installHook(keccak256("hook.1inch.swap"), deployed.oneInchSwapHook);
        console.log("[6/6] 1inch swap hook deployed and installed");
    }

    function _printSummary(DeployedContracts memory deployed, MultiChainConfig memory) internal view {
        console.log("\n========================================");
        console.log("  DEPLOYMENT COMPLETE ON CHAIN:", block.chainid);
        console.log("========================================");
        console.log("Implementation:  ", deployed.implementation);
        console.log("VaultModule:     ", deployed.vaultModule);
        console.log("Proxy:           ", deployed.proxy);
        console.log("Deposit Hook:    ", deployed.depositHook);
        console.log("Redeem Hook:     ", deployed.redeemHook);
        console.log("1inch Swap Hook: ", deployed.oneInchSwapHook);
        console.log("----------------------------------------");
        console.log("Vault Name:      ", deployed.vaultName);
        console.log("Vault Symbol:    ", deployed.vaultSymbol);
        console.log("Asset:           ", deployed.asset);
        console.log("========================================");
    }
}

/// @title PredictMultiChainAddress
/// @notice Predicts the MetaWallet proxy address for multi-chain deployment
/// @dev Uses production.json config to predict the same address across all chains
contract PredictMultiChainAddress is Script, DeploymentManager {
    function run() external view {
        MultiChainConfig memory config = readMainnetConfig();

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt = bytes32(uint256(uint160(config.roles.deployer)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(config.external_.factory);
        address predictedAddress = factory.predictDeterministicAddress(fullSalt);

        console.log("=== MULTI-CHAIN ADDRESS PREDICTION ===");
        console.log("Factory:", config.external_.factory);
        console.log("Deployer:", config.roles.deployer);
        console.log("Salt:", vm.toString(config.deployment.salt));
        console.log("Full Salt:", vm.toString(fullSalt));
        console.log("");
        console.log("PREDICTED PROXY ADDRESS:", predictedAddress);
        console.log("");
        console.log("This address will be the same on all chains");
        console.log("configured in production.json");
        console.log("=======================================");
    }
}

/// @title ValidateMultiChainConfig
/// @notice Validates the production.json configuration before deployment
contract ValidateMultiChainConfig is Script, DeploymentManager {
    function run() external view {
        MultiChainConfig memory config = readMainnetConfig();
        uint256 chainCount = getChainCount();

        console.log("=== PRODUCTION CONFIG VALIDATION ===");
        console.log("");
        console.log("Deployment Settings:");
        console.log("  Salt:", vm.toString(config.deployment.salt));
        console.log("  Deploy Mock Assets:", config.deployment.deployMockAssets);
        console.log("");
        console.log("Roles:");
        console.log("  Owner:", config.roles.owner);
        console.log("  Deployer:", config.roles.deployer);
        console.log("");
        console.log("External Contracts:");
        console.log("  Factory:", config.external_.factory);
        console.log("  Registry:", config.external_.registry);
        console.log("  Asset:", config.external_.asset);
        console.log("");
        console.log("Vault Config:");
        console.log("  Name:", config.vault.name);
        console.log("  Symbol:", config.vault.symbol);
        console.log("  Account ID:", config.vault.accountId);
        console.log("");
        console.log("Chains to deploy (", chainCount, "):");

        for (uint256 i = 0; i < chainCount; i++) {
            ChainConfig memory chain = getChainConfig(i);
            console.log("  [", i + 1, "]", chain.name);
            console.log("      Chain ID:", chain.chainId);
            console.log("      RPC Env:", chain.rpcEnvVar);
            console.log("      Verify:", chain.verify);
        }

        console.log("");
        console.log("====================================");

        // Validate
        require(config.roles.owner != address(0), "Owner address not set");
        require(config.roles.deployer != address(0), "Deployer address not set");
        require(config.external_.factory != address(0), "Factory address not set");
        require(config.external_.registry != address(0), "Registry address not set");
        require(config.external_.asset != address(0), "Asset address not set");
        require(chainCount > 0, "No chains configured");

        console.log("CONFIG VALIDATION: PASSED");
    }
}
