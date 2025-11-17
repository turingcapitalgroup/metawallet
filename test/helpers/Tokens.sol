// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { USDC_MAINNET } from "metawallet/src/helpers/AddressBook.sol";

uint256 constant _1_USDC = 1e6;
uint256 constant _1_USDCE = 1e6;

function getTokensList(string memory chain) pure returns (address[] memory) {
    if (keccak256(abi.encodePacked(chain)) == keccak256(abi.encodePacked("MAINNET"))) {
        address[] memory tokens = new address[](1);
        tokens[0] = USDC_MAINNET;
        return tokens;
    } else {
        revert("InvalidChain");
    }
}
