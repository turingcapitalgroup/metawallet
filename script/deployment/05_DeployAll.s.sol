// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";

import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";
import { MinimalUUPSFactory } from "minimal-uups-factory/MinimalUUPSFactory.sol";

import { MockERC20, MockRegistry } from "../helpers/MockContracts.sol";
import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployAllScript
/// @notice One-command deployment: mocks (if needed) + implementation + proxy + VaultModule + hooks
/// @dev Convenience script that runs all deployment steps in sequence
contract DeployAllScript is Script, DeploymentManager {
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

    /// @notice Deploy with default settings (writeToJson = true)
    function run() external returns (DeployedContracts memory) {
        return run(true);
    }

    /// @notice Deploy all contracts with configurable JSON writing
    /// @param writeToJson Whether to write deployed addresses to JSON output
    /// @return deployed The deployed contract addresses
    function run(bool writeToJson) public returns (DeployedContracts memory deployed) {
        // Read network configuration from JSON
        NetworkConfig memory config = readNetworkConfig();
        logConfig(config);

        // Check for existing deployment output (for testnets like sepolia)
        DeploymentOutput memory existing = readDeploymentOutput();

        vm.startBroadcast();

        deployed.asset = config.external_.asset;
        deployed.factory = config.external_.factory;
        deployed.registry = config.external_.registry;

        // Handle mock vs real assets based on config
        if (config.deployment.deployMockAssets) {
            // For testnets: check if mock assets already exist in output JSON AND on-chain
            if (
                existing.contracts.mockAsset != address(0) && existing.contracts.mockFactory != address(0)
                    && existing.contracts.mockRegistry != address(0) && existing.contracts.mockAsset.code.length > 0
                    && existing.contracts.mockFactory.code.length > 0 && existing.contracts.mockRegistry.code.length > 0
            ) {
                // Use existing mock assets from previous deployment
                deployed.asset = existing.contracts.mockAsset;
                deployed.factory = existing.contracts.mockFactory;
                deployed.registry = existing.contracts.mockRegistry;
                _log("[0/6] Using existing mock assets from deployment output:");
                _log("Mock Asset:", deployed.asset);
                _log("Mock Factory:", deployed.factory);
                _log("Mock Registry:", deployed.registry);
            } else {
                // Deploy new mock assets (JSON is stale or contracts don't exist on-chain)
                _deployMocks(deployed, config.roles.owner, writeToJson);
            }
        } else {
            // Use external addresses from config (for sepolia with real contracts or other testnets)
            require(deployed.asset != address(0), "Missing asset address in config");
            require(deployed.factory != address(0), "Missing factory address in config");
            require(deployed.registry != address(0), "Missing registry address in config");
            _log("[0/6] Using external addresses from config:");
            _log("Asset:", deployed.asset);
            _log("Factory:", deployed.factory);
            _log("Registry:", deployed.registry);
        }

        // Deploy core contracts
        _deployCore(deployed, writeToJson);

        // Deploy proxy
        _deployProxy(deployed, config, writeToJson);

        // Setup VaultModule and hooks
        _setupVaultAndHooks(deployed, config, writeToJson);

        vm.stopBroadcast();

        // Print summary
        _printSummary(deployed, config);

        return deployed;
    }

    function _deployMocks(DeployedContracts memory deployed, address owner, bool writeToJson) internal {
        _log("[0/6] Deploying mock assets for testing...");

        MockERC20 mockAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        deployed.asset = address(mockAsset);
        if (writeToJson) {
            writeContractAddress("mockAsset", deployed.asset);
        }
        _log("Mock Asset deployed:", deployed.asset);

        mockAsset.mint(owner, 1_000_000 * 10 ** 6);

        MockRegistry mockRegistry = new MockRegistry();
        deployed.registry = address(mockRegistry);
        if (writeToJson) {
            writeContractAddress("mockRegistry", deployed.registry);
        }
        _log("Mock Registry deployed:", deployed.registry);

        MinimalUUPSFactory mockFactory = new MinimalUUPSFactory();
        deployed.factory = address(mockFactory);
        if (writeToJson) {
            writeContractAddress("mockFactory", deployed.factory);
        }
        _log("Mock Factory deployed:", deployed.factory);
    }

    function _deployCore(DeployedContracts memory deployed, bool writeToJson) internal {
        deployed.implementation = address(new MetaWallet());
        if (writeToJson) {
            writeContractAddress("implementation", deployed.implementation);
        }
        _log("[1/6] MetaWallet implementation:", deployed.implementation);

        deployed.vaultModule = address(new VaultModule());
        if (writeToJson) {
            writeContractAddress("vaultModule", deployed.vaultModule);
        }
        _log("[2/6] VaultModule:", deployed.vaultModule);
    }

    function _deployProxy(DeployedContracts memory deployed, NetworkConfig memory config, bool writeToJson) internal {
        // Salt format: [20 bytes caller address][12 bytes custom salt]
        // The factory checks that shr(96, salt) == caller
        bytes32 fullSalt =
            bytes32(uint256(uint160(msg.sender)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalUUPSFactory factoryContract = MinimalUUPSFactory(deployed.factory);
        address predictedAddress = factoryContract.predictDeterministicAddress(deployed.implementation, fullSalt);
        _log("Predicted proxy address:", predictedAddress);

        string memory accountId = config.vault.accountId;
        bytes memory initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, config.roles.owner, IRegistry(deployed.registry), accountId
        );
        deployed.proxy = factoryContract.deployDeterministicAndCall(deployed.implementation, fullSalt, initData);
        if (writeToJson) {
            writeContractAddress("proxy", deployed.proxy);
        }
        _log("[3/6] Proxy deployed:", deployed.proxy);

        require(deployed.proxy == predictedAddress, "Address mismatch!");
    }

    function _setupVaultAndHooks(
        DeployedContracts memory deployed,
        NetworkConfig memory config,
        bool writeToJson
    )
        internal
    {
        MetaWallet metaWallet = MetaWallet(payable(deployed.proxy));

        // Grant ADMIN_ROLE (1 << 0 = 1) to the deployer so we can addFunctions
        // The owner can grant roles, and we ARE the owner during broadcast
        metaWallet.grantRoles(msg.sender, 1); // ADMIN_ROLE = 1
        _log("ADMIN_ROLE granted to deployer");

        // Setup VaultModule
        bytes4[] memory vaultSelectors = VaultModule(deployed.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, deployed.vaultModule, false);
        VaultModule(deployed.proxy).initializeVault(deployed.asset, config.vault.name, config.vault.symbol);
        _log("[4/6] VaultModule initialized");

        // Deploy and install ERC4626 hooks
        deployed.depositHook = address(new ERC4626ApproveAndDepositHook(deployed.proxy));
        deployed.redeemHook = address(new ERC4626RedeemHook(deployed.proxy));
        if (writeToJson) {
            writeContractAddress("depositHook", deployed.depositHook);
            writeContractAddress("redeemHook", deployed.redeemHook);
        }

        metaWallet.installHook(keccak256("hook.erc4626.deposit"), deployed.depositHook);
        metaWallet.installHook(keccak256("hook.erc4626.redeem"), deployed.redeemHook);
        _log("[5/6] ERC4626 hooks deployed and installed");

        // Deploy 1inch swap hook
        deployed.oneInchSwapHook = address(new OneInchSwapHook(deployed.proxy));
        if (writeToJson) {
            writeContractAddress("oneInchSwapHook", deployed.oneInchSwapHook);
        }
        metaWallet.installHook(keccak256("hook.1inch.swap"), deployed.oneInchSwapHook);
        _log("[6/6] 1inch swap hook deployed and installed");
    }

    function _printSummary(DeployedContracts memory deployed, NetworkConfig memory config) internal view {
        _log("========================================");
        _log("       DEPLOYMENT COMPLETE");
        _log("========================================");
        _log("Implementation:  ", deployed.implementation);
        _log("VaultModule:     ", deployed.vaultModule);
        _log("Proxy:           ", deployed.proxy);
        _log("Deposit Hook:    ", deployed.depositHook);
        _log("Redeem Hook:     ", deployed.redeemHook);
        _log("1inch Swap Hook: ", deployed.oneInchSwapHook);
        _log("----------------------------------------");
        _log("Vault Name:      ", config.vault.name);
        _log("Vault Symbol:    ", config.vault.symbol);
        _log("Asset:           ", deployed.asset);
        _log("========================================");
    }
}
