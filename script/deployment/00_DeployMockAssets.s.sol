// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";

import { MinimalSmartAccountFactory } from "minimal-smart-account/MinimalSmartAccountFactory.sol";

import { MockERC20, MockRegistry } from "../helpers/MockContracts.sol";
import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployMockAssetsScript
/// @notice Deploys mock assets for local testing (factory, registry, ERC20)
/// @dev Only used for localhost/testnet deployments
contract DeployMockAssetsScript is Script, DeploymentManager {
    struct MockAssets {
        address asset;
        address registry;
        address factory;
    }

    /// @notice Deploy with default settings (writeToJson = true)
    function run() external returns (MockAssets memory) {
        return run(true);
    }

    /// @notice Deploy mock assets with configurable JSON writing
    /// @param writeToJson Whether to write deployed addresses to JSON output
    /// @return assets The deployed mock asset addresses
    function run(bool writeToJson) public returns (MockAssets memory assets) {
        NetworkConfig memory config = readNetworkConfig();
        logConfig(config);

        require(config.deployment.deployMockAssets, "Mock assets deployment disabled in config");

        _log("=== DEPLOYING MOCK ASSETS ===");

        vm.startBroadcast();

        // Deploy mock asset (USDC-like)
        MockERC20 mockAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        assets.asset = address(mockAsset);
        if (writeToJson) {
            writeContractAddress("mockAsset", assets.asset);
        }
        _log("Mock Asset deployed:", assets.asset);

        // Mint tokens to owner
        mockAsset.mint(config.roles.owner, 1_000_000 * 10 ** 6);
        _log("Minted 1M mUSDC to owner");

        // Deploy mock registry
        MockRegistry mockRegistry = new MockRegistry();
        assets.registry = address(mockRegistry);
        if (writeToJson) {
            writeContractAddress("mockRegistry", assets.registry);
        }
        _log("Mock Registry deployed:", assets.registry);

        // Deploy factory
        MinimalSmartAccountFactory mockFactory = new MinimalSmartAccountFactory();
        assets.factory = address(mockFactory);
        if (writeToJson) {
            writeContractAddress("mockFactory", assets.factory);
        }
        _log("Mock Factory deployed:", assets.factory);

        vm.stopBroadcast();

        _log("=== MOCK ASSETS DEPLOYMENT COMPLETE ===");
        _log("Mock Asset:   ", assets.asset);
        _log("Mock Registry:", assets.registry);
        _log("Mock Factory: ", assets.factory);
        _log("========================================");

        return assets;
    }
}
