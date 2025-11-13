// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev All error codes use contract-specific prefixes for easier debugging:
///      - HE*: HookExecution errors
///      - MW*: MetaWallet errors
///      - H4D*: ERC4626ApproveAndDepositHook errors
///      - H4R*: ERC4626RedeemHook errors

// HookExecution Errors
string constant HOOKEXECUTION_INVALID_HOOK_ADDRESS = "HE1";
string constant HOOKEXECUTION_HOOK_ALREADY_INSTALLED = "HE2";
string constant HOOKEXECUTION_HOOK_NOT_INSTALLED = "HE3";
string constant HOOKEXECUTION_EMPTY_HOOK_CHAIN = "HE4";

// MetaWallet Errors
string constant METAWALLET_WRONG_ROLE = "MW1";
string constant METAWALLET_ZERO_ADDRESS = "MW2";

// ERC4626ApproveAndDepositHook Errors
string constant HOOK4626DEPOSIT_INVALID_HOOK_DATA = "H4D1";
string constant HOOK4626DEPOSIT_HOOK_NOT_INITIALIZED = "H4D2";
string constant HOOK4626DEPOSIT_HOOK_ALREADY_INITIALIZED = "H4D3";
string constant HOOK4626DEPOSIT_INSUFFICIENT_SHARES = "H4D4";
string constant HOOK4626DEPOSIT_PREVIOUS_HOOK_NO_OUTPUT = "H4D5";
string constant HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND = "H4D6";

// ERC4626RedeemHook Errors
string constant HOOK4626REDEEM_INVALID_HOOK_DATA = "H4R1";
string constant HOOK4626REDEEM_HOOK_NOT_INITIALIZED = "H4R2";
string constant HOOK4626REDEEM_HOOK_ALREADY_INITIALIZED = "H4R3";
string constant HOOK4626REDEEM_INSUFFICIENT_ASSETS = "H4R4";
string constant HOOK4626REDEEM_PREVIOUS_HOOK_NOT_FOUND = "H4R5";
string constant HOOK4626REDEEM_PREVIOUS_HOOK_NO_OUTPUT = "H4R6";

