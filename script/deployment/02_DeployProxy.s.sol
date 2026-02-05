// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";
import { MinimalUUPSFactory } from "minimal-uups-factory/MinimalUUPSFactory.sol";

import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployProxyScript
/// @notice Deploys a MetaWallet proxy with VaultModule using the MinimalSmartAccountFactory
/// @dev Step 2 in the deployment sequence. Uses CREATE2 for deterministic addresses across chains.
///      Requires implementation and vaultModule to be deployed first.
contract DeployProxyScript is Script, DeploymentManager {
    function run() external returns (address proxy) {
        NetworkConfig memory config = readNetworkConfig();
        DeploymentOutput memory existing = readDeploymentOutput();

        // Validate required deployments exist
        validateCoreDeployments(existing);
        logConfig(config);

        // Determine factory and registry addresses
        address factoryAddr = config.external_.factory;
        address registryAddr = config.external_.registry;

        // Use mock addresses if deployed
        if (existing.contracts.mockFactory != address(0)) {
            factoryAddr = existing.contracts.mockFactory;
            console.log("Using mock factory:", factoryAddr);
        }
        if (existing.contracts.mockRegistry != address(0)) {
            registryAddr = existing.contracts.mockRegistry;
            console.log("Using mock registry:", registryAddr);
        }

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt =
            bytes32(uint256(uint160(msg.sender)) << 96) | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalUUPSFactory factory = MinimalUUPSFactory(factoryAddr);

        address predictedAddress = factory.predictDeterministicAddress(existing.contracts.implementation, fullSalt);
        console.log("Predicted proxy address:", predictedAddress);

        bytes memory initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, config.roles.owner, IRegistry(registryAddr), config.vault.accountId
        );

        vm.startBroadcast();

        // Deploy proxy
        proxy = factory.deployDeterministicAndCall(existing.contracts.implementation, fullSalt, initData);
        writeContractAddress("proxy", proxy);
        console.log("[1/3] Proxy deployed:", proxy);

        require(proxy == predictedAddress, "Address mismatch!");

        // Grant ADMIN_ROLE to deployer
        MetaWallet metaWallet = MetaWallet(payable(proxy));
        metaWallet.grantRoles(msg.sender, 1); // ADMIN_ROLE = 1
        console.log("[2/3] ADMIN_ROLE granted to deployer");

        // Setup VaultModule
        bytes4[] memory vaultSelectors = VaultModule(existing.contracts.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, existing.contracts.vaultModule, false);

        // Determine asset address
        address assetAddr = config.external_.asset;
        if (existing.contracts.mockAsset != address(0)) {
            assetAddr = existing.contracts.mockAsset;
            console.log("Using mock asset:", assetAddr);
        }

        VaultModule(proxy).initializeVault(assetAddr, config.vault.name, config.vault.symbol);
        console.log("[3/3] VaultModule initialized");

        vm.stopBroadcast();

        console.log("\n=== PROXY DEPLOYMENT COMPLETE ===");
        console.log("Proxy:        ", proxy);
        console.log("Vault Name:   ", config.vault.name);
        console.log("Vault Symbol: ", config.vault.symbol);
        console.log("Asset:        ", assetAddr);
        console.log("=================================");
    }
}
