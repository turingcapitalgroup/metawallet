// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev All error codes use contract-specific prefixes for easier debugging:
///      - HE*: HookExecution errors
///      - VM*: VaultModule errors
///      - H4D*: ERC4626ApproveAndDepositHook errors
///      - H4R*: ERC4626RedeemHook errors
///      - H1I*: OneInchSwapHook errors
///      - MN*: MidnightModule errors
///      - HM*: MidnightHook errors

// HookExecution Errors
string constant HOOKEXECUTION_INVALID_HOOK_ADDRESS = "HE1";
string constant HOOKEXECUTION_HOOK_ALREADY_INSTALLED = "HE2";
string constant HOOKEXECUTION_HOOK_NOT_INSTALLED = "HE3";
string constant HOOKEXECUTION_EMPTY_HOOK_CHAIN = "HE4";
string constant HOOKEXECUTION_DEADLINE_EXPIRED = "HE5";
string constant HOOKEXECUTION_INVALID_NONCE = "HE6";

// VaultModule Errors
string constant VAULTMODULE_ALREADY_INITIALIZED = "VM1";
string constant VAULTMODULE_INVALID_ASSET_DECIMALS = "VM2";
string constant VAULTMODULE_PAUSED = "VM3";
string constant VAULTMODULE_MISMATCHED_ARRAYS = "VM4";
string constant VAULTMODULE_DELTA_EXCEEDS_MAX = "VM5";
string constant VAULTMODULE_INVALID_BPS = "VM6";
string constant VAULTMODULE_INSUFFICIENT_IDLE = "VM7";

// ERC4626ApproveAndDepositHook Errors
string constant HOOK4626DEPOSIT_INVALID_HOOK_DATA = "H4D1";
string constant HOOK4626DEPOSIT_INSUFFICIENT_SHARES = "H4D4";
string constant HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND = "H4D6";
string constant HOOK4626DEPOSIT_VAULT_NOT_ALLOWED = "H4D7";
string constant HOOK4626DEPOSIT_INVALID_VAULT = "H4D8";

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
string constant HOOKONEINCH_RESIDUAL_SOURCE_TOKENS = "H1I6";
string constant HOOKONEINCH_INVALID_FLAGS = "H1I7";
string constant HOOKONEINCH_INACTIVE_CONTEXT = "H1I8";

// MidnightModule Errors
string constant MIDNIGHT_INVALID_ADDRESS = "MN1";
string constant MIDNIGHT_NOT_CONFIGURED = "MN2";
string constant MIDNIGHT_ONLY_MIDNIGHT = "MN3";
string constant MIDNIGHT_UNAUTHORIZED = "MN4";
string constant MIDNIGHT_INVALID_BUYER = "MN5";
string constant MIDNIGHT_INVALID_SELLER = "MN6";
string constant MIDNIGHT_INVALID_RECEIVER = "MN7";
string constant MIDNIGHT_INVALID_MARKET = "MN8";
string constant MIDNIGHT_INVALID_LOAN_TOKEN = "MN9";
string constant MIDNIGHT_INVALID_LIQUIDATION_STEP = "MN10";
string constant MIDNIGHT_INVALID_PLACEHOLDER_OFFSET = "MN11";
string constant MIDNIGHT_LIQUIDATION_CALL_FAILED = "MN12";
string constant MIDNIGHT_INSUFFICIENT_LIQUIDITY = "MN13";
string constant MIDNIGHT_INSUFFICIENT_STEP_OUTPUT = "MN14";

// MidnightHook Errors
string constant HOOKMIDNIGHT_INVALID_HOOK_DATA = "HM1";
string constant HOOKMIDNIGHT_INACTIVE_CONTEXT = "HM2";
string constant HOOKMIDNIGHT_INSUFFICIENT_OUTPUT = "HM3";

