// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MinimalSmartAccountFactory } from "minimal-smart-account/MinimalSmartAccountFactory.sol";

import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title PredictProxyAddressScript
/// @notice Predicts the MetaWallet proxy address without deploying
contract PredictProxyAddressScript is Script, DeploymentManager {
    function run() external view {
        NetworkConfig memory config = readNetworkConfig();

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt = bytes32(uint256(uint160(config.roles.deployer)) << 96)
            | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(config.external_.factory);
        address predictedAddress = factory.predictDeterministicAddress(fullSalt);

        console.log("=== PROXY ADDRESS PREDICTION ===");
        console.log("Factory:   ", config.external_.factory);
        console.log("Deployer:  ", config.roles.deployer);
        console.log("Salt:      ", vm.toString(config.deployment.salt));
        console.log("");
        console.log("PREDICTED ADDRESS:", predictedAddress);
        console.log("================================");
    }
}

/// @title PredictMainnetAddressScript
/// @notice Predicts the MetaWallet proxy address for mainnet multi-chain deployment
/// @dev Uses mainnet.json config to predict the same address across all chains
contract PredictMainnetAddressScript is Script, DeploymentManager {
    function run() external view {
        MultiChainConfig memory config = readMainnetConfig();

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt = bytes32(uint256(uint160(config.roles.deployer)) << 96)
            | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalSmartAccountFactory factory = MinimalSmartAccountFactory(config.external_.factory);
        address predictedAddress = factory.predictDeterministicAddress(fullSalt);

        console.log("=== MAINNET ADDRESS PREDICTION ===");
        console.log("Factory:   ", config.external_.factory);
        console.log("Deployer:  ", config.roles.deployer);
        console.log("Salt:      ", vm.toString(config.deployment.salt));
        console.log("Full Salt: ", vm.toString(fullSalt));
        console.log("");
        console.log("PREDICTED PROXY ADDRESS:", predictedAddress);
        console.log("");
        console.log("This address will be the same on all chains");
        console.log("configured in mainnet.json");
        console.log("==================================");
    }
}

/// @title ValidateMainnetConfigScript
/// @notice Validates the mainnet.json configuration before deployment
contract ValidateMainnetConfigScript is Script, DeploymentManager {
    function run() external view {
        MultiChainConfig memory config = readMainnetConfig();
        uint256 chainCount = getChainCount();

        console.log("=== MAINNET CONFIG VALIDATION ===");
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
        console.log("  Name Prefix:", config.vault.namePrefix);
        console.log("  Symbol Prefix:", config.vault.symbolPrefix);
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
        console.log("=================================");

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
