// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

/// @title MockERC20
/// @notice Mock ERC20 token for local testing
contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MockRegistry
/// @notice Mock Registry for local testing
contract MockRegistry is IRegistry {
    mapping(address => mapping(address => mapping(bytes4 => bool))) public allowed;

    function authorizeCall(address, bytes4, bytes calldata) external pure override {
        // Always allow for testing
    }

    function isSelectorAllowed(address, address, bytes4) external pure override returns (bool) {
        return true; // Always allow for testing
    }
}
