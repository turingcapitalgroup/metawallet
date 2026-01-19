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
    // VERBOSE LOGGING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Controls whether deployment scripts log to console
    /// @dev Set to false in tests to reduce noise
    bool public verbose = true;

    /// @notice Sets the verbose logging flag
    /// @param _verbose Whether to enable verbose logging
    function setVerbose(bool _verbose) public {
        verbose = _verbose;
    }

    /// @dev Internal log helper - string only
    function _log(string memory message) internal view {
        if (verbose) console.log(message);
    }

    /// @dev Internal log helper - string + string
    function _log(string memory message, string memory value) internal view {
        if (verbose) console.log(message, value);
    }

    /// @dev Internal log helper - string + address
    function _log(string memory message, address value) internal view {
        if (verbose) console.log(message, value);
    }

    /// @dev Internal log helper - string + uint256
    function _log(string memory message, uint256 value) internal view {
        if (verbose) console.log(message, value);
    }

    /// @dev Internal log helper - string + bool
    function _log(string memory message, bool value) internal view {
        if (verbose) console.log(message, value);
    }

    /// @dev Internal log helper - string + bytes32
    function _log(string memory message, bytes32 value) internal view {
        if (verbose) console.log(message, vm.toString(value));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTI-WALLET CONFIGURATION STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct MultiWalletConfig {
        string network;
        uint256 chainId;
        RoleAddresses roles;
        SharedAddresses shared;
        DeploymentSettings deployment;
        WalletConfig[] wallets;
    }

    struct RoleAddresses {
        address owner;
        address deployer;
    }

    struct SharedAddresses {
        address factory;
        address registry;
    }

    struct WalletConfig {
        string id;
        address asset;
        VaultConfig vault;
        bytes32 salt;
    }

    struct VaultConfig {
        string name;
        string symbol;
    }

    struct DeploymentSettings {
        bool deployMockAssets;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTI-WALLET OUTPUT STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct MultiWalletOutput {
        uint256 chainId;
        string network;
        uint256 timestamp;
        SharedContractAddresses shared;
        WalletDeployment[] wallets;
    }

    struct SharedContractAddresses {
        address implementation;
        address vaultModule;
        address mockFactory;
        address mockRegistry;
    }

    struct WalletDeployment {
        string id;
        address asset;
        address proxy;
        address depositHook;
        address redeemHook;
        address oneInchSwapHook;
        address mockAsset;
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

    /// @notice Reads the multi-wallet configuration from JSON
    /// @return config The parsed multi-wallet configuration
    function readMultiWalletConfig() internal view returns (MultiWalletConfig memory config) {
        string memory network = getCurrentNetwork();
        string memory configPath = string.concat("deployments/config/", network, ".json");
        require(vm.exists(configPath), string.concat("Config file not found: ", configPath));

        string memory json = vm.readFile(configPath);

        config.network = json.readString(".network");
        config.chainId = json.readUint(".chainId");

        // Parse role addresses
        config.roles.owner = json.readAddress(".roles.owner");
        config.roles.deployer = json.readAddress(".roles.deployer");

        // Parse shared addresses
        config.shared.factory = json.readAddress(".shared.factory");
        config.shared.registry = json.readAddress(".shared.registry");

        // Parse deployment settings
        config.deployment.deployMockAssets = json.readBool(".deployment.deployMockAssets");

        // Parse wallets array
        uint256 walletCount = _getWalletCount(json);
        config.wallets = new WalletConfig[](walletCount);

        for (uint256 i = 0; i < walletCount; i++) {
            string memory prefix = string.concat(".wallets[", vm.toString(i), "]");
            config.wallets[i].id = json.readString(string.concat(prefix, ".id"));
            config.wallets[i].asset = json.readAddress(string.concat(prefix, ".asset"));
            config.wallets[i].vault.name = json.readString(string.concat(prefix, ".vault.name"));
            config.wallets[i].vault.symbol = json.readString(string.concat(prefix, ".vault.symbol"));
            config.wallets[i].salt = json.readBytes32(string.concat(prefix, ".salt"));
        }

        return config;
    }

    /// @dev Gets the wallet count from JSON by iteratively checking indices
    /// @notice Using parseRaw on complex nested arrays causes memory allocation errors in Foundry
    function _getWalletCount(string memory json) private pure returns (uint256) {
        uint256 count = 0;
        // Iterate until we find an index that doesn't exist
        while (true) {
            string memory idKey = string.concat(".wallets[", vm.toString(count), "].id");
            try vm.parseJsonString(json, idKey) returns (string memory) {
                count++;
            } catch {
                break;
            }
        }
        return count;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OUTPUT READING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Reads existing multi-wallet deployment output from JSON
    /// @return output The parsed multi-wallet deployment output
    function readMultiWalletOutput() internal view returns (MultiWalletOutput memory output) {
        string memory network = getCurrentNetwork();
        string memory outputPath = string.concat("deployments/output/", network, "/wallets.json");

        if (!vm.exists(outputPath)) {
            output.network = network;
            output.chainId = block.chainid;
            return output;
        }

        string memory json = vm.readFile(outputPath);
        output.chainId = json.readUint(".chainId");
        output.network = json.readString(".network");
        output.timestamp = json.readUint(".timestamp");

        // Parse shared contract addresses
        if (_keyExists(json, ".shared.implementation")) {
            output.shared.implementation = json.readAddress(".shared.implementation");
        }
        if (_keyExists(json, ".shared.vaultModule")) {
            output.shared.vaultModule = json.readAddress(".shared.vaultModule");
        }
        if (_keyExists(json, ".shared.mockFactory")) {
            output.shared.mockFactory = json.readAddress(".shared.mockFactory");
        }
        if (_keyExists(json, ".shared.mockRegistry")) {
            output.shared.mockRegistry = json.readAddress(".shared.mockRegistry");
        }

        // Parse wallet deployments
        uint256 walletCount = _getOutputWalletCount(json);
        output.wallets = new WalletDeployment[](walletCount);

        for (uint256 i = 0; i < walletCount; i++) {
            string memory prefix = string.concat(".wallets[", vm.toString(i), "]");
            if (_keyExists(json, string.concat(prefix, ".id"))) {
                output.wallets[i].id = json.readString(string.concat(prefix, ".id"));
            }
            if (_keyExists(json, string.concat(prefix, ".asset"))) {
                output.wallets[i].asset = json.readAddress(string.concat(prefix, ".asset"));
            }
            if (_keyExists(json, string.concat(prefix, ".proxy"))) {
                output.wallets[i].proxy = json.readAddress(string.concat(prefix, ".proxy"));
            }
            if (_keyExists(json, string.concat(prefix, ".depositHook"))) {
                output.wallets[i].depositHook = json.readAddress(string.concat(prefix, ".depositHook"));
            }
            if (_keyExists(json, string.concat(prefix, ".redeemHook"))) {
                output.wallets[i].redeemHook = json.readAddress(string.concat(prefix, ".redeemHook"));
            }
            if (_keyExists(json, string.concat(prefix, ".oneInchSwapHook"))) {
                output.wallets[i].oneInchSwapHook = json.readAddress(string.concat(prefix, ".oneInchSwapHook"));
            }
            if (_keyExists(json, string.concat(prefix, ".mockAsset"))) {
                output.wallets[i].mockAsset = json.readAddress(string.concat(prefix, ".mockAsset"));
            }
        }

        return output;
    }

    /// @dev Gets the wallet count from output JSON
    function _getOutputWalletCount(string memory json) private pure returns (uint256) {
        try vm.parseJsonBytes(json, ".wallets") returns (bytes memory walletsRaw) {
            bytes[] memory wallets = abi.decode(walletsRaw, (bytes[]));
            return wallets.length;
        } catch {
            return 0;
        }
    }

    /// @dev Helper to check if a JSON key exists
    function _keyExists(string memory json, string memory key) private pure returns (bool) {
        try vm.parseJsonAddress(json, key) returns (address) {
            return true;
        } catch {
            // Try string for non-address fields
            try vm.parseJsonString(json, key) returns (string memory) {
                return true;
            } catch {
                return false;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OUTPUT WRITING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Writes the full multi-wallet deployment output to JSON
    /// @param output The deployment output to write
    function writeMultiWalletOutput(MultiWalletOutput memory output) internal {
        string memory network = getCurrentNetwork();
        string memory outputDir = string.concat("deployments/output/", network);
        string memory outputPath = string.concat(outputDir, "/wallets.json");

        // Ensure directory exists
        if (!vm.exists(outputDir)) {
            vm.createDir(outputDir, true);
        }

        output.chainId = block.chainid;
        output.network = network;
        output.timestamp = block.timestamp;

        string memory json = _serializeMultiWalletOutput(output);
        vm.writeFile(outputPath, json);

        _log("Multi-wallet output written to:", outputPath);
    }

    /// @dev Serializes multi-wallet output to JSON string
    function _serializeMultiWalletOutput(MultiWalletOutput memory output) private pure returns (string memory) {
        string memory json = "{\n";
        json = string.concat(json, '  "chainId": ', vm.toString(output.chainId), ",\n");
        json = string.concat(json, '  "network": "', output.network, '",\n');
        json = string.concat(json, '  "timestamp": ', vm.toString(output.timestamp), ",\n");

        // Shared contracts
        json = string.concat(json, '  "shared": {\n');
        json = string.concat(json, '    "implementation": "', vm.toString(output.shared.implementation), '",\n');
        json = string.concat(json, '    "vaultModule": "', vm.toString(output.shared.vaultModule), '",\n');
        json = string.concat(json, '    "mockFactory": "', vm.toString(output.shared.mockFactory), '",\n');
        json = string.concat(json, '    "mockRegistry": "', vm.toString(output.shared.mockRegistry), '"\n');
        json = string.concat(json, "  },\n");

        // Wallets array
        json = string.concat(json, '  "wallets": [\n');
        for (uint256 i = 0; i < output.wallets.length; i++) {
            json = string.concat(json, "    {\n");
            json = string.concat(json, '      "id": "', output.wallets[i].id, '",\n');
            json = string.concat(json, '      "asset": "', vm.toString(output.wallets[i].asset), '",\n');
            json = string.concat(json, '      "proxy": "', vm.toString(output.wallets[i].proxy), '",\n');
            json = string.concat(json, '      "depositHook": "', vm.toString(output.wallets[i].depositHook), '",\n');
            json = string.concat(json, '      "redeemHook": "', vm.toString(output.wallets[i].redeemHook), '",\n');
            json = string.concat(
                json, '      "oneInchSwapHook": "', vm.toString(output.wallets[i].oneInchSwapHook), '",\n'
            );
            json = string.concat(json, '      "mockAsset": "', vm.toString(output.wallets[i].mockAsset), '"\n');
            json = string.concat(json, "    }");
            if (i < output.wallets.length - 1) {
                json = string.concat(json, ",");
            }
            json = string.concat(json, "\n");
        }
        json = string.concat(json, "  ]\n");
        json = string.concat(json, "}");

        return json;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Validates the multi-wallet configuration
    /// @param config The configuration to validate
    function validateMultiWalletConfig(MultiWalletConfig memory config) internal pure {
        require(config.roles.owner != address(0), "Missing owner address");
        require(config.wallets.length > 0, "No wallets configured");

        for (uint256 i = 0; i < config.wallets.length; i++) {
            require(bytes(config.wallets[i].id).length > 0, "Missing wallet id");
            require(bytes(config.wallets[i].vault.name).length > 0, "Missing vault name");
            require(bytes(config.wallets[i].vault.symbol).length > 0, "Missing vault symbol");
        }
    }

    /// @notice Validates that shared contracts are deployed
    /// @param output The existing deployment output
    function validateSharedDeployments(MultiWalletOutput memory output) internal pure {
        require(output.shared.implementation != address(0), "Implementation not deployed");
        require(output.shared.vaultModule != address(0), "VaultModule not deployed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOGGING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Logs the multi-wallet configuration to console
    /// @param config The configuration to log
    function logMultiWalletConfig(MultiWalletConfig memory config) internal view {
        _log("=== MULTI-WALLET DEPLOYMENT CONFIGURATION ===");
        _log("Network:", config.network);
        _log("Chain ID:", config.chainId);
        _log("Owner:", config.roles.owner);
        _log("Deployer:", config.roles.deployer);
        _log("Factory:", config.shared.factory);
        _log("Registry:", config.shared.registry);
        _log("Deploy Mock Assets:", config.deployment.deployMockAssets);
        _log("Number of Wallets:", config.wallets.length);
        _log("=============================================");

        for (uint256 i = 0; i < config.wallets.length; i++) {
            _log(string.concat("--- Wallet ", vm.toString(i + 1), " ---"));
            _log("ID:", config.wallets[i].id);
            _log("Asset:", config.wallets[i].asset);
            _log("Vault Name:", config.wallets[i].vault.name);
            _log("Vault Symbol:", config.wallets[i].vault.symbol);
            _log("Salt:", config.wallets[i].salt);
        }
    }

    /// @notice Logs deployed addresses to console
    /// @param output The deployment output to log
    function logMultiWalletOutput(MultiWalletOutput memory output) internal view {
        _log("=== DEPLOYED ADDRESSES ===");
        _log("Network:", output.network);
        _log("Implementation:", output.shared.implementation);
        _log("VaultModule:", output.shared.vaultModule);

        for (uint256 i = 0; i < output.wallets.length; i++) {
            _log(string.concat("--- Wallet: ", output.wallets[i].id, " ---"));
            _log("Asset:", output.wallets[i].asset);
            _log("Proxy:", output.wallets[i].proxy);
            _log("Deposit Hook:", output.wallets[i].depositHook);
            _log("Redeem Hook:", output.wallets[i].redeemHook);
            _log("1inch Swap Hook:", output.wallets[i].oneInchSwapHook);
        }
        _log("==========================");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER: Find wallet deployment by ID
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Finds a wallet deployment by ID in the output
    /// @param output The deployment output
    /// @param walletId The wallet ID to find
    /// @return index The index of the wallet (-1 if not found)
    function findWalletIndex(
        MultiWalletOutput memory output,
        string memory walletId
    )
        internal
        pure
        returns (int256 index)
    {
        for (uint256 i = 0; i < output.wallets.length; i++) {
            if (_strEq(output.wallets[i].id, walletId)) {
                return int256(i);
            }
        }
        return -1;
    }

    /// @dev String comparison helper
    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LEGACY COMPATIBILITY (for old single-wallet scripts)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Legacy single-wallet configuration struct
    /// @notice DEPRECATED: Use MultiWalletConfig instead
    struct NetworkConfig {
        string network;
        uint256 chainId;
        RoleAddresses roles;
        ExternalAddresses external_;
        LegacyVaultConfig vault;
        LegacyDeploymentSettings deployment;
    }

    struct ExternalAddresses {
        address factory;
        address registry;
        address asset;
    }

    struct LegacyVaultConfig {
        string name;
        string symbol;
        string namePrefix;
        string symbolPrefix;
        string accountId;
    }

    struct LegacyDeploymentSettings {
        bytes32 salt;
        bool deployMockAssets;
    }

    /// @dev Legacy single-wallet output struct
    /// @notice DEPRECATED: Use MultiWalletOutput instead
    struct DeploymentOutput {
        uint256 chainId;
        string network;
        string accountId;
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

    /// @notice Reads legacy network configuration (for backward compatibility)
    /// @dev Converts multi-wallet config to single-wallet format using first wallet
    /// @return config The parsed network configuration (first wallet only)
    function readNetworkConfig() internal view returns (NetworkConfig memory config) {
        MultiWalletConfig memory multiConfig = readMultiWalletConfig();

        config.network = multiConfig.network;
        config.chainId = multiConfig.chainId;
        config.roles = multiConfig.roles;

        // Use shared addresses + first wallet's asset
        config.external_.factory = multiConfig.shared.factory;
        config.external_.registry = multiConfig.shared.registry;
        if (multiConfig.wallets.length > 0) {
            config.external_.asset = multiConfig.wallets[0].asset;
            config.vault.name = multiConfig.wallets[0].vault.name;
            config.vault.symbol = multiConfig.wallets[0].vault.symbol;
            config.vault.accountId = multiConfig.wallets[0].id;
            config.deployment.salt = multiConfig.wallets[0].salt;
        }

        config.deployment.deployMockAssets = multiConfig.deployment.deployMockAssets;

        return config;
    }

    /// @notice Reads legacy deployment output (for backward compatibility)
    /// @dev Reads from legacy file format if exists, otherwise returns empty
    /// @return output The parsed deployment output
    function readDeploymentOutput() internal view returns (DeploymentOutput memory output) {
        NetworkConfig memory config = readNetworkConfig();
        return readDeploymentOutput(config.vault.accountId);
    }

    /// @notice Reads legacy deployment output by accountId
    /// @param accountId The account identifier
    /// @return output The parsed deployment output
    function readDeploymentOutput(string memory accountId) internal view returns (DeploymentOutput memory output) {
        string memory network = getCurrentNetwork();
        string memory outputPath = string.concat("deployments/output/", network, "/", accountId, ".json");

        if (!vm.exists(outputPath)) {
            output.network = network;
            output.chainId = block.chainid;
            output.accountId = accountId;
            return output;
        }

        string memory json = vm.readFile(outputPath);
        output.chainId = json.readUint(".chainId");
        output.network = json.readString(".network");
        output.accountId = json.readString(".accountId");
        output.timestamp = json.readUint(".timestamp");

        // Parse contract addresses with existence checks
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

    /// @notice Writes a contract address to legacy format (for backward compatibility)
    /// @param contractName The contract name
    /// @param contractAddress The deployed address
    function writeContractAddress(string memory contractName, address contractAddress) internal {
        NetworkConfig memory config = readNetworkConfig();
        writeContractAddress(config.vault.accountId, contractName, contractAddress);
    }

    /// @notice Writes a contract address to legacy format by accountId
    /// @param accountId The account identifier
    /// @param contractName The contract name
    /// @param contractAddress The deployed address
    function writeContractAddress(
        string memory accountId,
        string memory contractName,
        address contractAddress
    )
        internal
    {
        string memory network = getCurrentNetwork();
        string memory outputDir = string.concat("deployments/output/", network);
        string memory outputPath = string.concat(outputDir, "/", accountId, ".json");

        // Ensure directory exists
        if (!vm.exists(outputDir)) {
            vm.createDir(outputDir, true);
        }

        DeploymentOutput memory output = readDeploymentOutput(accountId);
        output.chainId = block.chainid;
        output.network = network;
        output.accountId = accountId;
        output.timestamp = block.timestamp;

        // Update specific contract address
        if (_strEq(contractName, "implementation")) output.contracts.implementation = contractAddress;
        else if (_strEq(contractName, "vaultModule")) output.contracts.vaultModule = contractAddress;
        else if (_strEq(contractName, "proxy")) output.contracts.proxy = contractAddress;
        else if (_strEq(contractName, "depositHook")) output.contracts.depositHook = contractAddress;
        else if (_strEq(contractName, "redeemHook")) output.contracts.redeemHook = contractAddress;
        else if (_strEq(contractName, "oneInchSwapHook")) output.contracts.oneInchSwapHook = contractAddress;
        else if (_strEq(contractName, "mockAsset")) output.contracts.mockAsset = contractAddress;
        else if (_strEq(contractName, "mockFactory")) output.contracts.mockFactory = contractAddress;
        else if (_strEq(contractName, "mockRegistry")) output.contracts.mockRegistry = contractAddress;

        string memory json = _serializeLegacyOutput(output);
        vm.writeFile(outputPath, json);

        _log(string.concat(contractName, " written to: "), outputPath);
    }

    /// @dev Serializes legacy output to JSON
    function _serializeLegacyOutput(DeploymentOutput memory output) private pure returns (string memory) {
        string memory json = "{";
        json = string.concat(json, '"chainId":', vm.toString(output.chainId), ",");
        json = string.concat(json, '"network":"', output.network, '",');
        json = string.concat(json, '"accountId":"', output.accountId, '",');
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

    /// @notice Logs legacy config (for backward compatibility)
    /// @param config The configuration to log
    function logConfig(NetworkConfig memory config) internal view {
        _log("=== DEPLOYMENT CONFIGURATION ===");
        _log("Network:", config.network);
        _log("Chain ID:", config.chainId);
        _log("Owner:", config.roles.owner);
        _log("Deployer:", config.roles.deployer);
        _log("Factory:", config.external_.factory);
        _log("Registry:", config.external_.registry);
        _log("Asset:", config.external_.asset);
        _log("Vault Name:", config.vault.name);
        _log("Vault Symbol:", config.vault.symbol);
        _log("Deploy Mock Assets:", config.deployment.deployMockAssets);
        _log("===============================");
    }

    /// @notice Validates legacy config (for backward compatibility)
    /// @param config The configuration to validate
    function validateConfig(NetworkConfig memory config) internal pure {
        require(config.roles.owner != address(0), "Missing owner address");
        require(bytes(config.vault.name).length > 0, "Missing vault name");
        require(bytes(config.vault.symbol).length > 0, "Missing vault symbol");
    }

    /// @notice Validates legacy core deployments (for backward compatibility)
    /// @param existing The existing deployment output
    function validateCoreDeployments(DeploymentOutput memory existing) internal pure {
        require(existing.contracts.implementation != address(0), "Implementation not deployed");
        require(existing.contracts.vaultModule != address(0), "VaultModule not deployed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LEGACY MULTI-CHAIN COMPATIBILITY (for 06_DeployMainnet.s.sol)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Legacy multi-chain configuration struct
    /// @notice DEPRECATED: Use MultiWalletConfig for new deployments
    struct MultiChainConfig {
        LegacyDeploymentSettings deployment;
        ChainConfig[] chains;
        RoleAddresses roles;
        ExternalAddresses external_;
        LegacyVaultConfig vault;
    }

    struct ChainConfig {
        string name;
        uint256 chainId;
        string rpcEnvVar;
        string etherscanApiKeyEnvVar;
        bool verify;
        ExternalAddresses external_;
    }

    /// @notice Reads legacy multi-chain mainnet config
    /// @dev DEPRECATED: This reads the old mainnet.json format or converts from new format
    function readMainnetConfig() internal view returns (MultiChainConfig memory config) {
        string memory configPath = "deployments/config/mainnet.json";
        require(vm.exists(configPath), "Mainnet config not found");

        string memory json = vm.readFile(configPath);

        // Check if this is the new format by looking for "wallets" array
        bool isNewFormat = _hasKey(json, ".wallets");

        if (isNewFormat) {
            // New multi-wallet format - convert to legacy
            MultiWalletConfig memory newConfig = readMultiWalletConfig();

            config.roles = newConfig.roles;
            config.deployment.deployMockAssets = newConfig.deployment.deployMockAssets;

            if (newConfig.wallets.length > 0) {
                config.deployment.salt = newConfig.wallets[0].salt;
                config.vault.name = newConfig.wallets[0].vault.name;
                config.vault.symbol = newConfig.wallets[0].vault.symbol;
                config.vault.namePrefix = newConfig.wallets[0].vault.name;
                config.vault.symbolPrefix = newConfig.wallets[0].vault.symbol;
                config.vault.accountId = newConfig.wallets[0].id;
                config.external_.asset = newConfig.wallets[0].asset;
            }

            config.external_.factory = newConfig.shared.factory;
            config.external_.registry = newConfig.shared.registry;

            // Empty chains array for new format
            config.chains = new ChainConfig[](0);
        } else {
            // Old multi-chain format - parse directly
            config.deployment.salt = json.readBytes32(".deployment.salt");
            config.roles.owner = json.readAddress(".roles.owner");
            config.roles.deployer = json.readAddress(".roles.deployer");

            // Read vault prefixes (old format uses prefixes)
            if (_hasKey(json, ".vault.namePrefix")) {
                config.vault.namePrefix = json.readString(".vault.namePrefix");
            }
            if (_hasKey(json, ".vault.symbolPrefix")) {
                config.vault.symbolPrefix = json.readString(".vault.symbolPrefix");
            }
            if (_hasKey(json, ".vault.accountId")) {
                config.vault.accountId = json.readString(".vault.accountId");
            }
        }

        return config;
    }

    /// @dev Helper to check if a JSON key exists (external call wrapper)
    function _hasKey(string memory json, string memory key) private pure returns (bool) {
        try vm.parseJsonBytes(json, key) returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Gets chain count from legacy mainnet config
    function getChainCount() internal view returns (uint256 count) {
        string memory configPath = "deployments/config/mainnet.json";
        string memory json = vm.readFile(configPath);

        try vm.parseJsonBytes(json, ".chains") returns (bytes memory chainsRaw) {
            bytes[] memory chains = abi.decode(chainsRaw, (bytes[]));
            return chains.length;
        } catch {
            return 0;
        }
    }

    /// @notice Gets chain config by index from legacy format
    function getChainConfig(uint256 index) internal view returns (ChainConfig memory chain) {
        string memory configPath = "deployments/config/mainnet.json";
        string memory json = vm.readFile(configPath);

        string memory prefix = string.concat(".chains[", vm.toString(index), "]");

        chain.name = json.readString(string.concat(prefix, ".name"));
        chain.chainId = json.readUint(string.concat(prefix, ".chainId"));
        chain.rpcEnvVar = json.readString(string.concat(prefix, ".rpcEnvVar"));
        chain.etherscanApiKeyEnvVar = json.readString(string.concat(prefix, ".etherscanApiKeyEnvVar"));
        chain.verify = json.readBool(string.concat(prefix, ".verify"));

        chain.external_.factory = json.readAddress(string.concat(prefix, ".external.factory"));
        chain.external_.registry = json.readAddress(string.concat(prefix, ".external.registry"));
        chain.external_.asset = json.readAddress(string.concat(prefix, ".external.asset"));

        return chain;
    }

    /// @notice Gets chain config for current network from legacy format
    function getChainConfigForCurrentNetwork() internal view returns (ChainConfig memory chain) {
        uint256 count = getChainCount();

        if (count == 0) {
            // New format - create ChainConfig from MultiWalletConfig
            MultiWalletConfig memory config = readMultiWalletConfig();
            chain.name = config.network;
            chain.chainId = config.chainId;
            chain.external_.factory = config.shared.factory;
            chain.external_.registry = config.shared.registry;
            if (config.wallets.length > 0) {
                chain.external_.asset = config.wallets[0].asset;
            }
            return chain;
        }

        for (uint256 i = 0; i < count; i++) {
            ChainConfig memory c = getChainConfig(i);
            if (c.chainId == block.chainid) {
                return c;
            }
        }
        revert(string.concat("Chain not found in config for chainId: ", vm.toString(block.chainid)));
    }

    /// @notice Logs legacy multi-chain config
    function logMultiChainConfig(MultiChainConfig memory config) internal view {
        _log("=== MULTI-CHAIN DEPLOYMENT CONFIG ===");
        _log("Owner:", config.roles.owner);
        _log("Deployer:", config.roles.deployer);
        _log("Vault Name/Prefix:", config.vault.name);
        _log("Vault Symbol/Prefix:", config.vault.symbol);
        _log("Salt:", config.deployment.salt);
        _log("=====================================");
    }

    /// @notice Logs legacy chain config
    function logChainConfig(ChainConfig memory chainConfig) internal view {
        _log("=== CHAIN CONFIG ===");
        _log("Chain:", chainConfig.name);
        _log("Chain ID:", chainConfig.chainId);
        _log("Factory:", chainConfig.external_.factory);
        _log("Registry:", chainConfig.external_.registry);
        _log("Asset:", chainConfig.external_.asset);
        _log("====================");
    }

    /// @notice Validates legacy production config
    function validateProductionConfig(MultiChainConfig memory config) internal pure {
        require(config.roles.owner != address(0), "Missing owner address");
        require(config.roles.deployer != address(0), "Missing deployer address");
    }

    /// @notice Validates legacy chain config
    function validateChainConfig(ChainConfig memory chainConfig) internal pure {
        require(chainConfig.external_.factory != address(0), "Missing factory address");
        require(chainConfig.external_.registry != address(0), "Missing registry address");
        require(chainConfig.external_.asset != address(0), "Missing asset address");
    }
}
