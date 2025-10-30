// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC7579Minimal } from "erc7579-minimal/ERC7579Minimal.sol";
import { MultiFacetProxy } from "kam/base/MultiFacetProxy.sol";

contract MetaWallet is ERC7579Minimal, MultiFacetProxy {
    /// @dev Authorize the sender to modify functions
    function _authorizeModifyFunctions(address sender) internal override {
        _checkRoles(ADMIN_ROLE);
    }
}
