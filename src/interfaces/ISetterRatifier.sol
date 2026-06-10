// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISetterRatifier {
    function setIsRootRatified(address maker, bytes32 root, bool enabled) external;
}
