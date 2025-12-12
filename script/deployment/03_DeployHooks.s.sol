// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { ERC4626RedeemHook } from "metawallet/src/hooks/ERC4626RedeemHook.sol";
import { OneInchSwapHook } from "metawallet/src/hooks/OneInchSwapHook.sol";

import { DeploymentManager } from "../utils/DeploymentManager.sol";

/// @title DeployHooksScript
/// @notice Deploys hooks for an existing MetaWallet proxy
/// @dev Step 3 in the deployment sequence. Requires proxy to be deployed first.
contract DeployHooksScript is Script, DeploymentManager {
    function run() external {
        DeploymentOutput memory existing = readDeploymentOutput();
        require(existing.contracts.proxy != address(0), "Proxy not deployed");

        address proxy = existing.contracts.proxy;
        console.log("MetaWallet proxy:", proxy);

        vm.startBroadcast();

        // Deploy ERC4626 deposit hook
        address depositHook = address(new ERC4626ApproveAndDepositHook(proxy));
        writeContractAddress("depositHook", depositHook);
        console.log("[1/3] Deposit Hook deployed:", depositHook);

        // Deploy ERC4626 redeem hook
        address redeemHook = address(new ERC4626RedeemHook(proxy));
        writeContractAddress("redeemHook", redeemHook);
        console.log("[2/3] Redeem Hook deployed:", redeemHook);

        // Deploy 1inch swap hook
        address oneInchSwapHook = address(new OneInchSwapHook(proxy));
        writeContractAddress("oneInchSwapHook", oneInchSwapHook);
        console.log("[3/3] 1inch Swap Hook deployed:", oneInchSwapHook);

        vm.stopBroadcast();

        console.log("\n=== HOOKS DEPLOYMENT COMPLETE ===");
        console.log("Deposit Hook:    ", depositHook);
        console.log("Redeem Hook:     ", redeemHook);
        console.log("1inch Swap Hook: ", oneInchSwapHook);
        console.log("=================================");
    }
}
