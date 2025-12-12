// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MetaWallet } from "metawallet/src/MetaWallet.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployImplementationScript
/// @notice Deploys MetaWallet implementation and VaultModule
/// @dev Step 1 in the deployment sequence
contract DeployImplementationScript is Script, DeploymentManager {
    function run() external {
        NetworkConfig memory config = readNetworkConfig();
        logConfig(config);

        vm.startBroadcast();

        // Deploy MetaWallet implementation
        address implementation = address(new MetaWallet());
        writeContractAddress("implementation", implementation);
        console.log("[1/2] MetaWallet implementation deployed:", implementation);

        // Deploy VaultModule
        address vaultModule = address(new VaultModule());
        writeContractAddress("vaultModule", vaultModule);
        console.log("[2/2] VaultModule deployed:", vaultModule);

        vm.stopBroadcast();

        console.log("\n=== IMPLEMENTATION DEPLOYMENT COMPLETE ===");
        console.log("Implementation: ", implementation);
        console.log("VaultModule:    ", vaultModule);
        console.log("==========================================");
    }
}
