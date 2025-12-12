// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MinimalSmartAccountFactory } from "minimal-smart-account/MinimalSmartAccountFactory.sol";

import { MockERC20, MockRegistry } from "../helpers/MockContracts.sol";
import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployMockAssetsScript
/// @notice Deploys mock assets for local testing (factory, registry, ERC20)
/// @dev Only used for localhost/testnet deployments
contract DeployMockAssetsScript is Script, DeploymentManager {
    function run() external {
        NetworkConfig memory config = readNetworkConfig();
        logConfig(config);

        require(config.deployment.deployMockAssets, "Mock assets deployment disabled in config");

        vm.startBroadcast();

        // Deploy mock asset (USDC-like)
        MockERC20 mockAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        writeContractAddress("mockAsset", address(mockAsset));
        console.log("Mock Asset deployed:", address(mockAsset));

        // Mint tokens to owner
        mockAsset.mint(config.roles.owner, 1_000_000 * 10 ** 6);
        console.log("Minted 1M mUSDC to owner");

        // Deploy mock registry
        MockRegistry mockRegistry = new MockRegistry();
        writeContractAddress("mockRegistry", address(mockRegistry));
        console.log("Mock Registry deployed:", address(mockRegistry));

        // Deploy factory
        MinimalSmartAccountFactory mockFactory = new MinimalSmartAccountFactory();
        writeContractAddress("mockFactory", address(mockFactory));
        console.log("Mock Factory deployed:", address(mockFactory));

        vm.stopBroadcast();

        console.log("\n=== MOCK ASSETS DEPLOYMENT COMPLETE ===");
        console.log("Mock Asset:    ", address(mockAsset));
        console.log("Mock Registry: ", address(mockRegistry));
        console.log("Mock Factory:  ", address(mockFactory));
        console.log("========================================");
    }
}
