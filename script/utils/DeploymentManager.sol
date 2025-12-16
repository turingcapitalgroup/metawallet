// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 as console } from "forge-std/console2.sol";

/// @title DeploymentManager
/// @notice Manages JSON-based deployment configuration and output for MetaWallet
/// @dev Provides utilities for reading config, writing deployed addresses, and network detection
abstract contract DeploymentManager is Script {
    using stdJson for string;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct NetworkConfig {
        string network;
        uint256 chainId;
        RoleAddresses roles;
        ExternalAddresses external_;
        VaultConfig vault;
        DeploymentSettings deployment;
    }

    struct RoleAddresses {
        address owner;
        address deployer;
    }

    struct ExternalAddresses {
        address factory;
        address registry;
        address asset;
    }

    struct VaultConfig {
        string name;
        string symbol;
        string namePrefix;
        string symbolPrefix;
        string accountId;
    }

    struct DeploymentSettings {
        bytes32 salt;
        bool deployMockAssets;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTI-CHAIN CONFIGURATION STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct MultiChainConfig {
        DeploymentSettings deployment;
        ChainConfig[] chains;
        RoleAddresses roles;
        ExternalAddresses external_;
        VaultConfig vault;
    }

    struct ChainConfig {
        string name;
        uint256 chainId;
        string rpcEnvVar;
        string etherscanApiKeyEnvVar;
        bool verify;
        ExternalAddresses external_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OUTPUT STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct DeploymentOutput {
        uint256 chainId;
        string network;
        uint256 timestamp;
        ContractAddresses contracts;
    }

    struct ContractAddresses {
        address implementation;
        address vaultModule;
        address proxy;
        address depositHook;
        address redeemHook;
        address oneInchSwapHook;
        address mockAsset;
        address mockFactory;
        address mockRegistry;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTI-CHAIN OUTPUT
    // ═══════════════════════════════════════════════════════════════════════════

    struct MultiChainDeploymentOutput {
        bytes32 salt;
        address expectedProxyAddress;
        ChainDeployment[] deployments;
    }

    struct ChainDeployment {
        string name;
        uint256 chainId;
        bool deployed;
        ContractAddresses contracts;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NETWORK DETECTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Determines the current network based on chain ID
    /// @return The network name string
    function getCurrentNetwork() internal view returns (string memory) {
        uint256 chainId = block.chainid;
        if (chainId == 1) return "mainnet";
        if (chainId == 11_155_111) return "sepolia";
        if (chainId == 31_337) return "localhost";
        if (chainId == 42_161) return "arbitrum";
        if (chainId == 10) return "optimism";
        if (chainId == 8453) return "base";
        if (chainId == 137) return "polygon";
        return "localhost";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION READING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Reads the network configuration from JSON
    /// @return config The parsed network configuration
    function readNetworkConfig() internal view returns (NetworkConfig memory config) {
        string memory network = getCurrentNetwork();
        string memory configPath = string.concat("deployments/config/", network, ".json");
        require(vm.exists(configPath), string.concat("Config file not found: ", configPath));

        string memory json = vm.readFile(configPath);

        config.network = json.readString(".network");
        config.chainId = json.readUint(".chainId");

        // Parse role addresses
        config.roles.owner = json.readAddress(".roles.owner");
        config.roles.deployer = json.readAddress(".roles.deployer");

        // Parse external addresses
        config.external_.factory = json.readAddress(".external.factory");
        config.external_.registry = json.readAddress(".external.registry");
        config.external_.asset = json.readAddress(".external.asset");

        // Parse vault config
        config.vault.name = json.readString(".vault.name");
        config.vault.symbol = json.readString(".vault.symbol");
        config.vault.accountId = json.readString(".vault.accountId");

        // Parse deployment settings
        config.deployment.salt = json.readBytes32(".deployment.salt");
        config.deployment.deployMockAssets = json.readBool(".deployment.deployMockAssets");

        return config;
    }

    /// @notice Reads multi-chain mainnet configuration from JSON
    /// @return config The parsed multi-chain configuration
    function readMainnetConfig() internal view returns (MultiChainConfig memory config) {
        string memory configPath = "deployments/config/mainnet.json";
        require(vm.exists(configPath), "Mainnet config not found");

        string memory json = vm.readFile(configPath);

        // Parse deployment settings
        config.deployment.salt = json.readBytes32(".deployment.salt");

        // Parse role addresses
        config.roles.owner = json.readAddress(".roles.owner");
        config.roles.deployer = json.readAddress(".roles.deployer");

        // Parse vault config - use prefixes for production (name/symbol derived from asset)
        config.vault.namePrefix = json.readString(".vault.namePrefix");
        config.vault.symbolPrefix = json.readString(".vault.symbolPrefix");
        config.vault.accountId = json.readString(".vault.accountId");

        // External addresses are now per-chain, read via getChainConfigForCurrentNetwork()
        return config;
    }

    /// @notice Gets chain count from mainnet config
    /// @return count Number of chains configured
    function getChainCount() internal view returns (uint256 count) {
        string memory configPath = "deployments/config/mainnet.json";
        string memory json = vm.readFile(configPath);
        // Parse the chains array length using raw JSON parsing
        bytes memory chainsRaw = json.parseRaw(".chains");
        // Decode as array of bytes to get length
        bytes[] memory chains = abi.decode(chainsRaw, (bytes[]));
        return chains.length;
    }

    /// @notice Gets a specific chain config by index
    /// @param index The chain index
    /// @return chain The chain configuration
    function getChainConfig(uint256 index) internal view returns (ChainConfig memory chain) {
        string memory configPath = "deployments/config/mainnet.json";
        string memory json = vm.readFile(configPath);

        string memory prefix = string.concat(".chains[", vm.toString(index), "]");

        chain.name = json.readString(string.concat(prefix, ".name"));
        chain.chainId = json.readUint(string.concat(prefix, ".chainId"));
        chain.rpcEnvVar = json.readString(string.concat(prefix, ".rpcEnvVar"));
        chain.etherscanApiKeyEnvVar = json.readString(string.concat(prefix, ".etherscanApiKeyEnvVar"));
        chain.verify = json.readBool(string.concat(prefix, ".verify"));

        // Parse per-chain external addresses
        chain.external_.factory = json.readAddress(string.concat(prefix, ".external.factory"));
        chain.external_.registry = json.readAddress(string.concat(prefix, ".external.registry"));
        chain.external_.asset = json.readAddress(string.concat(prefix, ".external.asset"));

        return chain;
    }

    /// @notice Gets chain config for the current network (by chainId)
    /// @return chain The chain configuration for the current network
    function getChainConfigForCurrentNetwork() internal view returns (ChainConfig memory chain) {
        uint256 count = getChainCount();
        for (uint256 i = 0; i < count; i++) {
            ChainConfig memory c = getChainConfig(i);
            if (c.chainId == block.chainid) {
                return c;
            }
        }
        revert(string.concat("Chain not found in mainnet.json for chainId: ", vm.toString(block.chainid)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OUTPUT READING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Reads existing deployment output from JSON
    /// @return output The parsed deployment output
    function readDeploymentOutput() internal view returns (DeploymentOutput memory output) {
        string memory network = getCurrentNetwork();
        string memory outputPath = string.concat("deployments/output/", network, "/addresses.json");

        if (!vm.exists(outputPath)) {
            output.network = network;
            output.chainId = block.chainid;
            return output;
        }

        string memory json = vm.readFile(outputPath);
        output.chainId = json.readUint(".chainId");
        output.network = json.readString(".network");
        output.timestamp = json.readUint(".timestamp");

        // Parse all contract addresses (with existence checks)
        if (_keyExists(json, ".contracts.implementation")) {
            output.contracts.implementation = json.readAddress(".contracts.implementation");
        }
        if (_keyExists(json, ".contracts.vaultModule")) {
            output.contracts.vaultModule = json.readAddress(".contracts.vaultModule");
        }
        if (_keyExists(json, ".contracts.proxy")) {
            output.contracts.proxy = json.readAddress(".contracts.proxy");
        }
        if (_keyExists(json, ".contracts.depositHook")) {
            output.contracts.depositHook = json.readAddress(".contracts.depositHook");
        }
        if (_keyExists(json, ".contracts.redeemHook")) {
            output.contracts.redeemHook = json.readAddress(".contracts.redeemHook");
        }
        if (_keyExists(json, ".contracts.oneInchSwapHook")) {
            output.contracts.oneInchSwapHook = json.readAddress(".contracts.oneInchSwapHook");
        }
        if (_keyExists(json, ".contracts.mockAsset")) {
            output.contracts.mockAsset = json.readAddress(".contracts.mockAsset");
        }
        if (_keyExists(json, ".contracts.mockFactory")) {
            output.contracts.mockFactory = json.readAddress(".contracts.mockFactory");
        }
        if (_keyExists(json, ".contracts.mockRegistry")) {
            output.contracts.mockRegistry = json.readAddress(".contracts.mockRegistry");
        }

        return output;
    }

    /// @notice Reads multi-chain deployment output
    /// @return output The parsed multi-chain deployment output
    function readMultiChainOutput() internal view returns (MultiChainDeploymentOutput memory output) {
        string memory outputPath = "deployments/output/multichain/addresses.json";

        if (!vm.exists(outputPath)) {
            return output;
        }

        string memory json = vm.readFile(outputPath);
        output.salt = json.readBytes32(".salt");
        output.expectedProxyAddress = json.readAddress(".expectedProxyAddress");

        return output;
    }

    /// @dev Helper to check if a JSON key exists
    function _keyExists(string memory json, string memory key) private pure returns (bool) {
        try vm.parseJsonAddress(json, key) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OUTPUT WRITING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Writes a contract address to the deployment output JSON
    /// @param contractName The name of the contract
    /// @param contractAddress The deployed address
    function writeContractAddress(string memory contractName, address contractAddress) internal {
        string memory network = getCurrentNetwork();
        string memory outputPath = string.concat("deployments/output/", network, "/addresses.json");

        DeploymentOutput memory output = readDeploymentOutput();
        output.chainId = block.chainid;
        output.network = network;
        output.timestamp = block.timestamp;

        // Update the specific contract address
        if (_strEq(contractName, "implementation")) {
            output.contracts.implementation = contractAddress;
        } else if (_strEq(contractName, "vaultModule")) {
            output.contracts.vaultModule = contractAddress;
        } else if (_strEq(contractName, "proxy")) {
            output.contracts.proxy = contractAddress;
        } else if (_strEq(contractName, "depositHook")) {
            output.contracts.depositHook = contractAddress;
        } else if (_strEq(contractName, "redeemHook")) {
            output.contracts.redeemHook = contractAddress;
        } else if (_strEq(contractName, "oneInchSwapHook")) {
            output.contracts.oneInchSwapHook = contractAddress;
        } else if (_strEq(contractName, "mockAsset")) {
            output.contracts.mockAsset = contractAddress;
        } else if (_strEq(contractName, "mockFactory")) {
            output.contracts.mockFactory = contractAddress;
        } else if (_strEq(contractName, "mockRegistry")) {
            output.contracts.mockRegistry = contractAddress;
        }

        string memory json = _serializeDeploymentOutput(output);
        vm.writeFile(outputPath, json);

        console.log(string.concat(contractName, " address written to: "), outputPath);
    }

    /// @dev Serializes deployment output to JSON string
    function _serializeDeploymentOutput(DeploymentOutput memory output) private pure returns (string memory) {
        string memory json = "{";
        json = string.concat(json, '"chainId":', vm.toString(output.chainId), ",");
        json = string.concat(json, '"network":"', output.network, '",');
        json = string.concat(json, '"timestamp":', vm.toString(output.timestamp), ",");
        json = string.concat(json, '"contracts":{');

        json = string.concat(json, '"implementation":"', vm.toString(output.contracts.implementation), '",');
        json = string.concat(json, '"vaultModule":"', vm.toString(output.contracts.vaultModule), '",');
        json = string.concat(json, '"proxy":"', vm.toString(output.contracts.proxy), '",');
        json = string.concat(json, '"depositHook":"', vm.toString(output.contracts.depositHook), '",');
        json = string.concat(json, '"redeemHook":"', vm.toString(output.contracts.redeemHook), '",');
        json = string.concat(json, '"oneInchSwapHook":"', vm.toString(output.contracts.oneInchSwapHook), '",');
        json = string.concat(json, '"mockAsset":"', vm.toString(output.contracts.mockAsset), '",');
        json = string.concat(json, '"mockFactory":"', vm.toString(output.contracts.mockFactory), '",');
        json = string.concat(json, '"mockRegistry":"', vm.toString(output.contracts.mockRegistry), '"');
        json = string.concat(json, "}}");

        return json;
    }

    /// @dev String comparison helper
    function _strEq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates the network configuration
    /// @param config The configuration to validate
    function validateConfig(NetworkConfig memory config) internal pure {
        require(config.roles.owner != address(0), "Missing owner address");
        require(bytes(config.vault.name).length > 0, "Missing vault name");
        require(bytes(config.vault.symbol).length > 0, "Missing vault symbol");
    }

    /// @notice Validates that required contracts are deployed
    /// @param existing The existing deployment output
    function validateCoreDeployments(DeploymentOutput memory existing) internal pure {
        require(existing.contracts.implementation != address(0), "Implementation not deployed");
        require(existing.contracts.vaultModule != address(0), "VaultModule not deployed");
    }

    /// @notice Validates production config for multi-chain deployment
    /// @param config The multi-chain configuration
    function validateProductionConfig(MultiChainConfig memory config) internal pure {
        require(config.roles.owner != address(0), "Missing owner address");
        require(config.roles.deployer != address(0), "Missing deployer address");
        require(bytes(config.vault.namePrefix).length > 0, "Missing vault name prefix");
        require(bytes(config.vault.symbolPrefix).length > 0, "Missing vault symbol prefix");
    }

    /// @notice Validates per-chain external addresses
    /// @param chainConfig The chain configuration to validate
    function validateChainConfig(ChainConfig memory chainConfig) internal pure {
        require(chainConfig.external_.factory != address(0), "Missing factory address for chain");
        require(chainConfig.external_.registry != address(0), "Missing registry address for chain");
        require(chainConfig.external_.asset != address(0), "Missing asset address for chain");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOGGING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Logs the configuration to console
    /// @param config The configuration to log
    function logConfig(NetworkConfig memory config) internal pure {
        console.log("=== DEPLOYMENT CONFIGURATION ===");
        console.log("Network:", config.network);
        console.log("Chain ID:", config.chainId);
        console.log("Owner:", config.roles.owner);
        console.log("Deployer:", config.roles.deployer);
        console.log("Factory:", config.external_.factory);
        console.log("Registry:", config.external_.registry);
        console.log("Asset:", config.external_.asset);
        console.log("Vault Name:", config.vault.name);
        console.log("Vault Symbol:", config.vault.symbol);
        console.log("Deploy Mock Assets:", config.deployment.deployMockAssets);
        console.log("===============================");
    }

    /// @notice Logs deployed addresses to console
    /// @param output The deployment output to log
    function logDeployment(DeploymentOutput memory output) internal pure {
        console.log("=== DEPLOYED ADDRESSES ===");
        console.log("Network:", output.network);
        console.log("Implementation:", output.contracts.implementation);
        console.log("VaultModule:", output.contracts.vaultModule);
        console.log("Proxy:", output.contracts.proxy);
        console.log("Deposit Hook:", output.contracts.depositHook);
        console.log("Redeem Hook:", output.contracts.redeemHook);
        console.log("1inch Swap Hook:", output.contracts.oneInchSwapHook);
        console.log("==========================");
    }

    /// @notice Logs multi-chain configuration
    /// @param config The multi-chain configuration
    function logMultiChainConfig(MultiChainConfig memory config) internal pure {
        console.log("=== MULTI-CHAIN DEPLOYMENT CONFIG ===");
        console.log("Owner:", config.roles.owner);
        console.log("Deployer:", config.roles.deployer);
        console.log("Vault Name Prefix:", config.vault.namePrefix);
        console.log("Vault Symbol Prefix:", config.vault.symbolPrefix);
        console.log("Salt:", vm.toString(config.deployment.salt));
        console.log("=====================================");
    }

    /// @notice Logs chain-specific configuration
    /// @param chainConfig The chain configuration to log
    function logChainConfig(ChainConfig memory chainConfig) internal pure {
        console.log("=== CHAIN CONFIG ===");
        console.log("Chain:", chainConfig.name);
        console.log("Chain ID:", chainConfig.chainId);
        console.log("Factory:", chainConfig.external_.factory);
        console.log("Registry:", chainConfig.external_.registry);
        console.log("Asset:", chainConfig.external_.asset);
        console.log("====================");
    }
}
