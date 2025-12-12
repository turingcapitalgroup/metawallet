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

    function run() external {
        // Read network configuration from JSON
        NetworkConfig memory config = readNetworkConfig();
        logConfig(config);

        // Check for existing deployment output (for testnets like sepolia)
        DeploymentOutput memory existing = readDeploymentOutput();

        vm.startBroadcast();

        DeployedContracts memory deployed;
        deployed.asset = config.external_.asset;
        deployed.factory = config.external_.factory;
        deployed.registry = config.external_.registry;

        // For testnets: check if mock assets already exist in output JSON AND on-chain
        if (config.deployment.deployMockAssets) {
            if (
                existing.contracts.mockAsset != address(0) && existing.contracts.mockFactory != address(0)
                    && existing.contracts.mockRegistry != address(0) && existing.contracts.mockAsset.code.length > 0
                    && existing.contracts.mockFactory.code.length > 0 && existing.contracts.mockRegistry.code.length > 0
            ) {
                // Use existing mock assets from previous deployment
                deployed.asset = existing.contracts.mockAsset;
                deployed.factory = existing.contracts.mockFactory;
                deployed.registry = existing.contracts.mockRegistry;
                console.log("\n[0/6] Using existing mock assets from deployment output:");
                console.log("Mock Asset:", deployed.asset);
                console.log("Mock Factory:", deployed.factory);
                console.log("Mock Registry:", deployed.registry);
            } else {
                // Deploy new mock assets (JSON is stale or contracts don't exist on-chain)
                _deployMocks(deployed, config.roles.owner);
            }
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
        bytes32 fullSalt =
            bytes32(uint256(uint160(msg.sender)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

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
