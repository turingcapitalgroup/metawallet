// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { Midnight } from "midnight/src/Midnight.sol";
import { SetterRatifier } from "midnight/src/ratifiers/SetterRatifier.sol";

contract MidnightProtocolDeployer {
    function deploy() external returns (address midnight, address setterRatifier) {
        Midnight deployedMidnight = new Midnight();
        midnight = address(deployedMidnight);
        setterRatifier = address(new SetterRatifier(midnight));
    }

    function testDeploysMidnightAndSetterRatifier() external {
        (address deployedMidnight, address deployedSetterRatifier) = this.deploy();
        require(deployedMidnight != address(0), "MIDNIGHT_NOT_DEPLOYED");
        require(deployedSetterRatifier != address(0), "RATIFIER_NOT_DEPLOYED");
    }
}
