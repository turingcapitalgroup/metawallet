// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev All error codes use contract-specific prefixes for easier debugging:
///      - HE*: HookExecution errors
///      - VM*: VaultModule errors
///      - H4D*: ERC4626ApproveAndDepositHook errors
///      - H4R*: ERC4626RedeemHook errors
///      - H1I*: OneInchSwapHook errors

// HookExecution Errors
string constant HOOKEXECUTION_INVALID_HOOK_ADDRESS = "HE1";
string constant HOOKEXECUTION_HOOK_ALREADY_INSTALLED = "HE2";
string constant HOOKEXECUTION_HOOK_NOT_INSTALLED = "HE3";
string constant HOOKEXECUTION_EMPTY_HOOK_CHAIN = "HE4";

// VaultModule Errors
string constant VAULTMODULE_ALREADY_INITIALIZED = "VM1";
string constant VAULTMODULE_INVALID_ASSET_DECIMALS = "VM2";
string constant VAULTMODULE_PAUSED = "VM3";
string constant VAULTMODULE_MISMATCHED_ARRAYS = "VM4";
string constant VAULTMODULE_DELTA_EXCEEDS_MAX = "VM5";
string constant VAULTMODULE_INVALID_BPS = "VM6";

// ERC4626ApproveAndDepositHook Errors
string constant HOOK4626DEPOSIT_INVALID_HOOK_DATA = "H4D1";
string constant HOOK4626DEPOSIT_INSUFFICIENT_SHARES = "H4D4";
string constant HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND = "H4D6";

// ERC4626RedeemHook Errors
string constant HOOK4626REDEEM_INVALID_HOOK_DATA = "H4R1";
string constant HOOK4626REDEEM_INSUFFICIENT_ASSETS = "H4R4";
string constant HOOK4626REDEEM_PREVIOUS_HOOK_NO_OUTPUT = "H4R6";

// OneInchSwapHook Errors
string constant HOOKONEINCH_INVALID_HOOK_DATA = "H1I1";
string constant HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND = "H1I2";
string constant HOOKONEINCH_INSUFFICIENT_OUTPUT = "H1I3";
string constant HOOKONEINCH_INVALID_ROUTER = "H1I4";
string constant HOOKONEINCH_ROUTER_NOT_ALLOWED = "H1I5";

