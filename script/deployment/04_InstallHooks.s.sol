// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { MetaWallet } from "metawallet/src/MetaWallet.sol";

import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title InstallHooksScript
/// @notice Installs hooks on an existing MetaWallet proxy
/// @dev Step 4 in the deployment sequence. Requires proxy and hooks to be deployed first.
contract InstallHooksScript is Script, DeploymentManager {
    function run() external {
        DeploymentOutput memory existing = readDeploymentOutput();
        require(existing.contracts.proxy != address(0), "Proxy not deployed");
        require(existing.contracts.depositHook != address(0), "Deposit hook not deployed");
        require(existing.contracts.redeemHook != address(0), "Redeem hook not deployed");

        console.log("MetaWallet proxy:", existing.contracts.proxy);

        vm.startBroadcast();

        MetaWallet metaWallet = MetaWallet(payable(existing.contracts.proxy));

        // Install ERC4626 deposit hook
        bytes32 depositHookId = keccak256("hook.erc4626.deposit");
        metaWallet.installHook(depositHookId, existing.contracts.depositHook);
        console.log("[1/3] Deposit hook installed");

        // Install ERC4626 redeem hook
        bytes32 redeemHookId = keccak256("hook.erc4626.redeem");
        metaWallet.installHook(redeemHookId, existing.contracts.redeemHook);
        console.log("[2/3] Redeem hook installed");

        // Install 1inch swap hook if deployed
        if (existing.contracts.oneInchSwapHook != address(0)) {
            bytes32 oneInchHookId = keccak256("hook.1inch.swap");
            metaWallet.installHook(oneInchHookId, existing.contracts.oneInchSwapHook);
            console.log("[3/3] 1inch swap hook installed");
        }

        vm.stopBroadcast();

        console.log("\n=== HOOKS INSTALLATION COMPLETE ===");
        console.log("Deposit Hook:    ", existing.contracts.depositHook);
        console.log("Redeem Hook:     ", existing.contracts.redeemHook);
        console.log("1inch Swap Hook: ", existing.contracts.oneInchSwapHook);
        console.log("===================================");
    }
}
