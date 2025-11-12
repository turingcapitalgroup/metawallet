// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, Vm, console2 } from "forge-std/Test.sol";
import { getTokensList } from "metawallet/test/helpers/Tokens.sol";
import { Utilities } from "metawallet/test/utils/Utilities.sol";

contract BaseTest is Test {
    struct Users {
        address payable owner;
        address payable admin;
        address payable executor;
        address payable alice;
        address payable bob;
        address payable charlie;
    }

    Utilities public utils;
    Users public users;
    uint256 public chainFork;

    function _setUp(string memory chain, uint256 forkBlock) internal virtual {
        if (vm.envOr("FORK", false)) {
            string memory rpc = vm.envString(string.concat("RPC_", chain));
            chainFork = vm.createSelectFork(rpc);
            vm.rollFork(forkBlock);
        }
        // Setup utils
        utils = new Utilities();

        address[] memory tokens = getTokensList(chain);

        // Create users for testing.
        users = Users({
            owner: utils.createUser("Owner", tokens),
            admin: utils.createUser("Admin", tokens),
            executor: utils.createUser("Executor", tokens),
            alice: utils.createUser("Alice", tokens),
            bob: utils.createUser("Bob", tokens),
            charlie: utils.createUser("Charlie", tokens)
        });

        // Make Alice both the caller and the origin.
        vm.startPrank({ msgSender: users.owner, txOrigin: users.owner });
    }
}
