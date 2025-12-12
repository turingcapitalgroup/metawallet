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

import { ERC20 } from "solady/tokens/ERC20.sol";

import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployMainnetScript
/// @notice Deploys MetaWallet to the current chain using mainnet.json config
/// @dev This script is called by deploy-mainnet.sh for each chain in sequence.
///      All chains get the same proxy address via CREATE2.
contract DeployMainnetScript is Script, DeploymentManager {
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
        string vaultName;
        string vaultSymbol;
    }

    function run() external {
        // Read mainnet configuration
        MultiChainConfig memory config = readMainnetConfig();
        logMultiChainConfig(config);

        // Validate config
        validateProductionConfig(config);

        vm.startBroadcast();

        DeployedContracts memory deployed;
        deployed.asset = config.external_.asset;
        deployed.factory = config.external_.factory;
        deployed.registry = config.external_.registry;

        // Derive vault name and symbol from asset
        (deployed.vaultName, deployed.vaultSymbol) = _deriveVaultNameAndSymbol(deployed.asset, config);

        // Deploy core contracts
        _deployCore(deployed);

        // Deploy proxy with deterministic address
        _deployProxy(deployed, config);

        // Setup VaultModule and hooks
        _setupVaultAndHooks(deployed, config);

        vm.stopBroadcast();

        // Print summary
        _printSummary(deployed);
    }

    function _deriveVaultNameAndSymbol(
        address asset,
        MultiChainConfig memory config
    )
        internal
        view
        returns (string memory name, string memory symbol)
    {
        // Get asset name and symbol
        string memory assetName;
        string memory assetSymbol;

        try ERC20(asset).name() returns (string memory n) {
            assetName = n;
        } catch {
            assetName = "Unknown";
        }

        try ERC20(asset).symbol() returns (string memory s) {
            assetSymbol = s;
        } catch {
            assetSymbol = "???";
        }

        // Derive vault name: "{namePrefix} {assetName}" e.g. "MetaVault USDC"
        name = string.concat(config.vault.namePrefix, " ", assetName);

        // Derive vault symbol: "{symbolPrefix}{assetSymbol}" e.g. "mvUSDC"
        symbol = string.concat(config.vault.symbolPrefix, assetSymbol);

        return (name, symbol);
    }

    function _deployCore(DeployedContracts memory deployed) internal {
        deployed.implementation = address(new MetaWallet());
        writeContractAddress("implementation", deployed.implementation);
        console.log("[1/6] MetaWallet implementation:", deployed.implementation);

        deployed.vaultModule = address(new VaultModule());
        writeContractAddress("vaultModule", deployed.vaultModule);
        console.log("[2/6] VaultModule:", deployed.vaultModule);
    }

    function _deployProxy(DeployedContracts memory deployed, MultiChainConfig memory config) internal {
        // Salt format: [20 bytes caller address][12 bytes custom salt]
        // This ensures the same address across all chains when using the same deployer + salt
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

    function _setupVaultAndHooks(DeployedContracts memory deployed, MultiChainConfig memory) internal {
        MetaWallet metaWallet = MetaWallet(payable(deployed.proxy));

        // Grant ADMIN_ROLE to deployer
        metaWallet.grantRoles(msg.sender, 1); // ADMIN_ROLE = 1
        console.log("ADMIN_ROLE granted to deployer");

        // Setup VaultModule with derived name/symbol
        bytes4[] memory vaultSelectors = VaultModule(deployed.vaultModule).selectors();
        metaWallet.addFunctions(vaultSelectors, deployed.vaultModule, false);
        VaultModule(deployed.proxy).initializeVault(deployed.asset, deployed.vaultName, deployed.vaultSymbol);
        console.log("[4/6] VaultModule initialized");
        console.log("  Vault Name:", deployed.vaultName);
        console.log("  Vault Symbol:", deployed.vaultSymbol);

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

    function _printSummary(DeployedContracts memory deployed) internal view {
        console.log("\n========================================");
        console.log("  DEPLOYMENT COMPLETE ON CHAIN:", block.chainid);
        console.log("========================================");
        console.log("Implementation:  ", deployed.implementation);
        console.log("VaultModule:     ", deployed.vaultModule);
        console.log("Proxy:           ", deployed.proxy);
        console.log("Deposit Hook:    ", deployed.depositHook);
        console.log("Redeem Hook:     ", deployed.redeemHook);
        console.log("1inch Swap Hook: ", deployed.oneInchSwapHook);
        console.log("----------------------------------------");
        console.log("Vault Name:      ", deployed.vaultName);
        console.log("Vault Symbol:    ", deployed.vaultSymbol);
        console.log("Asset:           ", deployed.asset);
        console.log("========================================");
    }
}
