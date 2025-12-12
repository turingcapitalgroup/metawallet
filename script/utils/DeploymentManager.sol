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
        string accountId;
    }

    struct DeploymentSettings {
        bytes32 salt;
        bool deployMockAssets;
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
}
