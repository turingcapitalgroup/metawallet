// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MetaWallet } from "metawallet/src/MetaWallet.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { MinimalSmartAccountFactory } from "minimal-smart-account/MinimalSmartAccountFactory.sol";
import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";

/// @title Deploy
/// @notice Deployment script for MetaWallet implementation and VaultModule
contract Deploy is Script {
    address public implementation;
    address public vaultModule;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        implementation = address(new MetaWallet());
        console.log("MetaWallet implementation deployed at:", implementation);

        vaultModule = address(new VaultModule());
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
contract DeployProxy is Script {
    struct DeployConfig {
        address factory;
        address implementation;
        address vaultModule;
        address registry;
        address owner;
        address asset;
        string accountId;
        string vaultName;
        string vaultSymbol;
        bytes32 salt;
    }

    function run() external returns (address proxy) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        DeployConfig memory cfg = _loadConfig(deployer);

        bytes32 fullSalt = bytes32(uint256(uint160(deployer))) | (cfg.salt >> 160);

        console.log("Chain ID:", block.chainid);
        console.log("Factory:", cfg.factory);
        console.log("Implementation:", cfg.implementation);
        console.log("VaultModule:", cfg.vaultModule);
        console.log("Owner:", cfg.owner);
        console.log("Asset:", cfg.asset);

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(cfg.factory);

        address predictedAddress = factory.predictDeterministicAddress(fullSalt);
        console.log("Predicted proxy address:", predictedAddress);

        vm.startBroadcast(deployerPrivateKey);

        proxy = factory.deployDeterministic(
            cfg.implementation, fullSalt, cfg.owner, IRegistry(cfg.registry), cfg.accountId
        );
        console.log("Proxy deployed at:", proxy);

        _setupVaultModule(proxy, cfg);

        vm.stopBroadcast();

        require(proxy == predictedAddress, "Address mismatch!");

        console.log("\n=== Deployment Summary ===");
        console.log("Proxy:", proxy);
        console.log("Vault Name:", cfg.vaultName);
        console.log("Vault Symbol:", cfg.vaultSymbol);
    }

    function _loadConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg.factory = vm.envAddress("FACTORY_ADDRESS");
        cfg.implementation = vm.envAddress("IMPLEMENTATION_ADDRESS");
        cfg.vaultModule = vm.envAddress("VAULT_MODULE_ADDRESS");
        cfg.registry = vm.envAddress("REGISTRY_ADDRESS");
        cfg.owner = vm.envOr("OWNER_ADDRESS", deployer);
        cfg.asset = vm.envAddress("ASSET_ADDRESS");
        cfg.accountId = vm.envOr("ACCOUNT_ID", string("metawallet.v1"));
        cfg.vaultName = vm.envOr("VAULT_NAME", string("Meta Vault"));
        cfg.vaultSymbol = vm.envOr("VAULT_SYMBOL", string("mVAULT"));
        cfg.salt = bytes32(vm.envOr("DEPLOY_SALT", uint256(0)));
    }

    function _setupVaultModule(address proxy, DeployConfig memory cfg) internal {
        MetaWallet metaWallet = MetaWallet(payable(proxy));

        bytes4[] memory vaultSelectors = VaultModule(cfg.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, cfg.vaultModule, false);
        console.log("VaultModule functions added");

        VaultModule(proxy).initializeVault(cfg.asset, cfg.vaultName, cfg.vaultSymbol);
        console.log("Vault initialized with asset:", cfg.asset);
    }
}

/// @title DeployProxyWithHooks
/// @notice Deploys a MetaWallet proxy with VaultModule and ERC4626 hooks
contract DeployProxyWithHooks is Script {
    struct DeployConfig {
        address factory;
        address implementation;
        address vaultModule;
        address registry;
        address owner;
        address asset;
        string accountId;
        string vaultName;
        string vaultSymbol;
        bytes32 salt;
    }

    function run() external returns (address proxy, address depositHook, address redeemHook) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        DeployConfig memory cfg = _loadConfig(deployer);

        bytes32 fullSalt = bytes32(uint256(uint160(deployer))) | (cfg.salt >> 160);

        console.log("Chain ID:", block.chainid);
        console.log("Factory:", cfg.factory);
        console.log("Implementation:", cfg.implementation);

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(cfg.factory);

        address predictedAddress = factory.predictDeterministicAddress(fullSalt);
        console.log("Predicted proxy address:", predictedAddress);

        vm.startBroadcast(deployerPrivateKey);

        proxy = factory.deployDeterministic(
            cfg.implementation, fullSalt, cfg.owner, IRegistry(cfg.registry), cfg.accountId
        );

        _setupVaultModule(proxy, cfg);

        (depositHook, redeemHook) = _deployAndInstallHooks(proxy);

        vm.stopBroadcast();

        require(proxy == predictedAddress, "Address mismatch!");

        console.log("\n=== Deployment Summary ===");
        console.log("Proxy:", proxy);
        console.log("Deposit Hook:", depositHook);
        console.log("Redeem Hook:", redeemHook);
    }

    function _loadConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg.factory = vm.envAddress("FACTORY_ADDRESS");
        cfg.implementation = vm.envAddress("IMPLEMENTATION_ADDRESS");
        cfg.vaultModule = vm.envAddress("VAULT_MODULE_ADDRESS");
        cfg.registry = vm.envAddress("REGISTRY_ADDRESS");
        cfg.owner = vm.envOr("OWNER_ADDRESS", deployer);
        cfg.asset = vm.envAddress("ASSET_ADDRESS");
        cfg.accountId = vm.envOr("ACCOUNT_ID", string("metawallet.v1"));
        cfg.vaultName = vm.envOr("VAULT_NAME", string("Meta Vault"));
        cfg.vaultSymbol = vm.envOr("VAULT_SYMBOL", string("mVAULT"));
        cfg.salt = bytes32(vm.envOr("DEPLOY_SALT", uint256(0)));
    }

    function _setupVaultModule(address proxy, DeployConfig memory cfg) internal {
        MetaWallet metaWallet = MetaWallet(payable(proxy));

        bytes4[] memory vaultSelectors = VaultModule(cfg.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, cfg.vaultModule, false);

        VaultModule(proxy).initializeVault(cfg.asset, cfg.vaultName, cfg.vaultSymbol);
    }

    function _deployAndInstallHooks(address proxy) internal returns (address depositHook, address redeemHook) {
        depositHook = address(new ERC4626ApproveAndDepositHook(proxy));
        redeemHook = address(new ERC4626RedeemHook(proxy));

        MetaWallet metaWallet = MetaWallet(payable(proxy));

        bytes32 depositHookId = keccak256("hook.erc4626.deposit");
        bytes32 redeemHookId = keccak256("hook.erc4626.redeem");

        metaWallet.installHook(depositHookId, depositHook);
        metaWallet.installHook(redeemHookId, redeemHook);
    }
}

/// @title PredictProxyAddress
/// @notice Predicts the MetaWallet proxy address without deploying
contract PredictProxyAddress is Script {
    function run() external view {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        bytes32 salt = bytes32(vm.envOr("DEPLOY_SALT", uint256(0)));

        bytes32 fullSalt = bytes32(uint256(uint160(deployer))) | (salt >> 160);

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(factoryAddress);
        address predictedAddress = factory.predictDeterministicAddress(fullSalt);

        console.log("Factory:", factoryAddress);
        console.log("Deployer:", deployer);
        console.log("Salt:", vm.toString(salt));
        console.log("Predicted proxy address:", predictedAddress);
    }
}

/// @title DeployHooks
/// @notice Deploys ERC4626 hooks for an existing MetaWallet
contract DeployHooks is Script {
    function run() external returns (address depositHook, address redeemHook) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address metaWalletAddress = vm.envAddress("METAWALLET_ADDRESS");

        console.log("Chain ID:", block.chainid);
        console.log("MetaWallet:", metaWalletAddress);

        vm.startBroadcast(deployerPrivateKey);

        depositHook = address(new ERC4626ApproveAndDepositHook(metaWalletAddress));
        redeemHook = address(new ERC4626RedeemHook(metaWalletAddress));

        console.log("Deposit Hook deployed at:", depositHook);
        console.log("Redeem Hook deployed at:", redeemHook);

        vm.stopBroadcast();
    }
}

/// @title InstallHooks
/// @notice Installs hooks on an existing MetaWallet
contract InstallHooks is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address metaWalletAddress = vm.envAddress("METAWALLET_ADDRESS");
        address depositHookAddress = vm.envAddress("DEPOSIT_HOOK_ADDRESS");
        address redeemHookAddress = vm.envAddress("REDEEM_HOOK_ADDRESS");

        console.log("Chain ID:", block.chainid);
        console.log("MetaWallet:", metaWalletAddress);

        vm.startBroadcast(deployerPrivateKey);

        MetaWallet metaWallet = MetaWallet(payable(metaWalletAddress));

        bytes32 depositHookId = keccak256("hook.erc4626.deposit");
        bytes32 redeemHookId = keccak256("hook.erc4626.redeem");

        metaWallet.installHook(depositHookId, depositHookAddress);
        metaWallet.installHook(redeemHookId, redeemHookAddress);

        console.log("Hooks installed successfully");

        vm.stopBroadcast();
    }
}

/// @title DeployAll
/// @notice One-command deployment: implementation + proxy + VaultModule + hooks
/// @dev Deploys everything needed for a fully functional MetaWallet
contract DeployAll is Script {
    struct DeployConfig {
        address factory;
        address registry;
        address owner;
        address asset;
        string accountId;
        string vaultName;
        string vaultSymbol;
        bytes32 salt;
    }

    struct DeployedAddresses {
        address implementation;
        address vaultModule;
        address proxy;
        address depositHook;
        address redeemHook;
    }

    function run() external returns (DeployedAddresses memory deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        DeployConfig memory cfg = _loadConfig(deployer);

        bytes32 fullSalt = bytes32(uint256(uint160(deployer))) | (cfg.salt >> 160);

        console.log("=== DeployAll: Full MetaWallet Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Factory:", cfg.factory);

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(cfg.factory);
        address predictedAddress = factory.predictDeterministicAddress(fullSalt);
        console.log("Predicted proxy address:", predictedAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy implementation contracts
        deployed.implementation = address(new MetaWallet());
        console.log("\n[1/5] MetaWallet implementation:", deployed.implementation);

        deployed.vaultModule = address(new VaultModule());
        console.log("[2/5] VaultModule:", deployed.vaultModule);

        // Step 2: Deploy proxy via factory
        deployed.proxy = factory.deployDeterministic(
            deployed.implementation, fullSalt, cfg.owner, IRegistry(cfg.registry), cfg.accountId
        );
        console.log("[3/5] Proxy deployed:", deployed.proxy);

        // Step 3: Setup VaultModule
        _setupVaultModule(deployed.proxy, deployed.vaultModule, cfg);
        console.log("[4/5] VaultModule initialized");

        // Step 4: Deploy and install hooks
        (deployed.depositHook, deployed.redeemHook) = _deployAndInstallHooks(deployed.proxy);
        console.log("[5/5] Hooks deployed and installed");

        vm.stopBroadcast();

        require(deployed.proxy == predictedAddress, "Address mismatch!");

        _printSummary(deployed, cfg);
    }

    function _loadConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg.factory = vm.envAddress("FACTORY_ADDRESS");
        cfg.registry = vm.envAddress("REGISTRY_ADDRESS");
        cfg.owner = vm.envOr("OWNER_ADDRESS", deployer);
        cfg.asset = vm.envAddress("ASSET_ADDRESS");
        cfg.accountId = vm.envOr("ACCOUNT_ID", string("metawallet.v1"));
        cfg.vaultName = vm.envOr("VAULT_NAME", string("Meta Vault"));
        cfg.vaultSymbol = vm.envOr("VAULT_SYMBOL", string("mVAULT"));
        cfg.salt = bytes32(vm.envOr("DEPLOY_SALT", uint256(0)));
    }

    function _setupVaultModule(address proxy, address vaultModuleAddr, DeployConfig memory cfg) internal {
        MetaWallet metaWallet = MetaWallet(payable(proxy));

        bytes4[] memory vaultSelectors = VaultModule(vaultModuleAddr).selectors();
        metaWallet.addFunctions(vaultSelectors, vaultModuleAddr, false);

        VaultModule(proxy).initializeVault(cfg.asset, cfg.vaultName, cfg.vaultSymbol);
    }

    function _deployAndInstallHooks(address proxy) internal returns (address depositHook, address redeemHook) {
        depositHook = address(new ERC4626ApproveAndDepositHook(proxy));
        redeemHook = address(new ERC4626RedeemHook(proxy));

        MetaWallet metaWallet = MetaWallet(payable(proxy));

        bytes32 depositHookId = keccak256("hook.erc4626.deposit");
        bytes32 redeemHookId = keccak256("hook.erc4626.redeem");

        metaWallet.installHook(depositHookId, depositHook);
        metaWallet.installHook(redeemHookId, redeemHook);
    }

    function _printSummary(DeployedAddresses memory deployed, DeployConfig memory cfg) internal pure {
        console.log("\n========================================");
        console.log("       DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("Implementation:  ", deployed.implementation);
        console.log("VaultModule:     ", deployed.vaultModule);
        console.log("Proxy:           ", deployed.proxy);
        console.log("Deposit Hook:    ", deployed.depositHook);
        console.log("Redeem Hook:     ", deployed.redeemHook);
        console.log("----------------------------------------");
        console.log("Vault Name:      ", cfg.vaultName);
        console.log("Vault Symbol:    ", cfg.vaultSymbol);
        console.log("Asset:           ", cfg.asset);
        console.log("========================================");
    }
}
