// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MinimalUUPSFactory } from "minimal-uups-factory/MinimalUUPSFactory.sol";

import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title PredictProxyAddressScript
/// @notice Predicts the MetaWallet proxy address without deploying
contract PredictProxyAddressScript is Script, DeploymentManager {
    function run() external view {
        NetworkConfig memory config = readNetworkConfig();
        address implementation = vm.envAddress("IMPLEMENTATION_ADDRESS");

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt = bytes32(uint256(uint160(config.roles.deployer)) << 96)
            | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalUUPSFactory factory = MinimalUUPSFactory(config.external_.factory);
        address predictedAddress = factory.predictDeterministicAddress(implementation, fullSalt);

        console.log("=== PROXY ADDRESS PREDICTION ===");
        console.log("Factory:       ", config.external_.factory);
        console.log("Implementation:", implementation);
        console.log("Deployer:      ", config.roles.deployer);
        console.log("Salt:          ", vm.toString(config.deployment.salt));
        console.log("");
        console.log("PREDICTED ADDRESS:", predictedAddress);
        console.log("================================");
    }
}

/// @title PredictMainnetAddressScript
/// @notice Predicts the MetaWallet proxy address for mainnet multi-chain deployment
/// @dev Uses mainnet.json config to predict the same address across all chains
///      NOTE: All chains must use the same factory address for CREATE2 to give same proxy address
contract PredictMainnetAddressScript is Script, DeploymentManager {
    function run() external view {
        MultiChainConfig memory config = readMainnetConfig();
        uint256 chainCount = getChainCount();
        address implementation = vm.envAddress("IMPLEMENTATION_ADDRESS");

        require(chainCount > 0, "No chains configured");

        // Get factory from first chain (all chains should have same factory for same proxy address)
        ChainConfig memory firstChain = getChainConfig(0);

        // Salt format: [20 bytes caller address][12 bytes custom salt]
        bytes32 fullSalt = bytes32(uint256(uint160(config.roles.deployer)) << 96)
            | (config.deployment.salt & bytes32(uint256(type(uint96).max)));

        MinimalUUPSFactory factory = MinimalUUPSFactory(firstChain.external_.factory);
        address predictedAddress = factory.predictDeterministicAddress(implementation, fullSalt);

        console.log("=== MAINNET ADDRESS PREDICTION ===");
        console.log("Implementation:", implementation);
        console.log("Deployer:      ", config.roles.deployer);
        console.log("Salt:          ", vm.toString(config.deployment.salt));
        console.log("Full Salt:     ", vm.toString(fullSalt));
        console.log("");
        console.log("PREDICTED PROXY ADDRESS:", predictedAddress);
        console.log("");
        console.log("Factory addresses per chain:");
        for (uint256 i = 0; i < chainCount; i++) {
            ChainConfig memory chain = getChainConfig(i);
            console.log("  ", chain.name, ":", chain.external_.factory);
        }
        console.log("");
        console.log("NOTE: All chains must use the same factory address");
        console.log("for the proxy to have the same address across chains");
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
        console.log("");
        console.log("Roles:");
        console.log("  Owner:", config.roles.owner);
        console.log("  Deployer:", config.roles.deployer);
        console.log("");
        console.log("Vault Config:");
        console.log("  Name Prefix:", config.vault.namePrefix);
        console.log("  Symbol Prefix:", config.vault.symbolPrefix);
        console.log("  Account ID:", config.vault.accountId);
        console.log("");
        console.log("Chains to deploy (", chainCount, "):");

        bool allValid = true;
        address firstFactory = address(0);

        for (uint256 i = 0; i < chainCount; i++) {
            ChainConfig memory chain = getChainConfig(i);
            console.log("");
            console.log("  [", i + 1, "]", chain.name);
            console.log("      Chain ID:", chain.chainId);
            console.log("      RPC Env:", chain.rpcEnvVar);
            console.log("      Verify:", chain.verify);
            console.log("      Factory:", chain.external_.factory);
            console.log("      Registry:", chain.external_.registry);
            console.log("      Asset:", chain.external_.asset);

            // Validate per-chain addresses
            if (chain.external_.factory == address(0)) {
                console.log("      ERROR: Factory not set!");
                allValid = false;
            }
            if (chain.external_.registry == address(0)) {
                console.log("      ERROR: Registry not set!");
                allValid = false;
            }
            if (chain.external_.asset == address(0)) {
                console.log("      ERROR: Asset not set!");
                allValid = false;
            }

            // Track factory consistency for same proxy address across chains
            if (i == 0) {
                firstFactory = chain.external_.factory;
            } else if (chain.external_.factory != firstFactory) {
                console.log("      WARNING: Factory differs from first chain - proxy address will be different!");
            }
        }

        console.log("");
        console.log("=================================");

        // Validate global config
        require(config.roles.owner != address(0), "Owner address not set");
        require(config.roles.deployer != address(0), "Deployer address not set");
        require(bytes(config.vault.namePrefix).length > 0, "Vault name prefix not set");
        require(bytes(config.vault.symbolPrefix).length > 0, "Vault symbol prefix not set");
        require(chainCount > 0, "No chains configured");
        require(allValid, "Some chain configurations are invalid");

        console.log("CONFIG VALIDATION: PASSED");
    }
}
