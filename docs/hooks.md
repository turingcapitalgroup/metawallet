# MetaWallet Hook System

## Table of Contents

1. [Hook System Overview](#1-hook-system-overview)
2. [Hook Lifecycle](#2-hook-lifecycle)
3. [Hook Chaining](#3-hook-chaining)
4. [ERC4626ApproveAndDepositHook](#4-erc4626approveanddeposithook)
5. [ERC4626RedeemHook](#5-erc4626redeemhook)
6. [OneInchSwapHook](#6-oneinchswaphook)
7. [Security Patterns](#7-security-patterns)
8. [Creating Custom Hooks](#8-creating-custom-hooks)

---

## 1. Hook System Overview

Hooks are the modular execution primitives of the MetaWallet system. Each hook
encapsulates a single strategy operation -- a vault deposit, a vault redemption,
a token swap -- and exposes it through a uniform interface (`IHook`). This design
lets the wallet compose arbitrarily complex DeFi strategies by chaining multiple
hooks together in a single atomic transaction.

### Why Hooks Exist

Traditional smart-wallet designs hard-code every supported operation into the
wallet contract itself. Adding a new protocol integration requires upgrading the
wallet logic. Hooks invert this relationship: the wallet knows *how to execute*
hooks, but each hook knows *what to execute*. New strategies ship as new hook
contracts, installed at runtime without modifying the wallet.

### Core Contracts

| Contract / Interface | Role |
|---|---|
| `IHook` | Minimal interface every hook must implement |
| `IHookResult` | Optional interface for hooks that produce an output consumable by the next hook |
| `IHookExecution` | Interface for the wallet-side hook management and execution engine |
| `HookExecution` | Abstract contract implementing the hook registry and execution pipeline |

### High-Level Architecture

```
+------------------+       +-------------------+       +-------------------+
|   MetaWallet     |       |   HookExecution   |       |   Concrete Hook   |
|  (Smart Account) |------>|   (abstract mixin)|------>|  (e.g. OneInch)   |
+------------------+       +-------------------+       +-------------------+
        |                         |                           |
        |  executeWithHookExecution()                         |
        |------------------------>|                           |
        |                         |  buildExecutions()        |
        |                         |-------------------------->|
        |                         |  initializeHookContext()  |
        |                         |-------------------------->|
        |                         |                           |
        |    _executeOperations() |                           |
        |<------------------------|                           |
        |                         |  finalizeHookContext()    |
        |                         |-------------------------->|
        |                         |                           |
```

---

## 2. Hook Lifecycle

Every hook passes through four distinct phases: **installation**, **build**,
**execution**, and **cleanup**.

### 2.1 Installation

Hooks are registered in the wallet's `HookExecutionStorage` via `_installHook`.
Each hook is identified by a `bytes32` key (typically a `keccak256` of a
human-readable name) and mapped to the hook contract address.

```solidity
// Example: install an ERC-4626 deposit hook
bytes32 hookId = keccak256("hook.erc4626.deposit");
_installHook(hookId, address(depositHook));
```

Storage layout (ERC-7201 namespaced):

```
HookExecutionStorage {
    mapping(bytes32 => address) hooks;        // hookId -> hook contract
    EnumerableSetLib.Bytes32Set   hookIds;    // enumerable set of all ids
}
```

Events emitted: `HookInstalled(hookId, hookAddress)`.

Uninstalling removes the mapping and the set entry, emitting
`HookUninstalled(hookId, hookAddress)`.

### 2.2 Execution Flow

When `executeWithHookExecution(HookExecution[] calldata)` is called, the
`HookExecution` abstract contract orchestrates the full pipeline in two internal
functions: `_buildExecutionChain` and `_processHookChain`.

```
            _executeHookExecution(hookExecutions[])
                        |
          +-------------+-------------+
          |                           |
  _buildExecutionChain()     _processHookChain()
          |                           |
          v                           v
  For each hook i:            1. For each hook i:
    resolve hookAddress            initializeHookContext()
    previousHook = hooks[i-1]      emit HookExecutionStarted
    execs[i] = hook.buildExecutions(
        previousHook, data)   2. _executeOperations(allExecs)
    flatten into allExecs
                              3. For each hook i:
                                   finalizeHookContext()
                                   emit HookExecutionCompleted
```

#### Phase 1: Build (`_buildExecutionChain`)

The engine iterates over every `HookExecution` entry, calls
`buildExecutions(previousHook, data)` on the resolved hook contract, and
collects the returned `Execution[]` arrays. It then flattens them into a single
`Execution[]` that represents the complete operation set.

Key detail: `previousHook` is `address(0)` for the first hook in the chain and
the address of the preceding hook for every subsequent one. This is how hooks
learn where to read dynamic amounts from.

#### Phase 2: Initialize Context

Before any execution happens, *every* hook in the chain receives
`initializeHookContext()`. This sets the `_executionContext` flag to `true`,
signalling that the hook is in an active execution window.

#### Phase 3: Execute

`_executeOperations(Execution[] memory)` is an abstract function that the
inheriting wallet contract must implement. It performs the actual low-level
calls (`target.call{value}(callData)`) and returns the raw results.

All executions from all hooks run sequentially in the flattened order.

#### Phase 4: Finalize and Cleanup

After all executions complete, every hook receives `finalizeHookContext()`.
This function:

- Sets `_executionContext` back to `false`
- Deletes all transient context structs (e.g., `_swapContext`,
  `_depositContext`, `_redeemContext`)
- Deletes any temporary storage used during dynamic resolution

This ensures zero state leaks between successive strategy executions.

### 2.3 Full Lifecycle Diagram

```
  INSTALL                    EXECUTE                           CLEANUP
  -------                    -------                           -------
  installHook(id, addr)      executeWithHookExecution([...])
        |                         |
        v                         v
  hooks[id] = addr          _buildExecutionChain
  hookIds.add(id)                 |
  emit HookInstalled              v
                            _processHookChain
                                  |
                       +----------+----------+
                       |          |          |
                       v          v          v
                  initialize   execute   finalize
                  HookContext   Ops      HookContext
                       |          |          |
                       v          v          v
                  _execution   low-level   delete context
                  Context=true  calls     _executionContext=false
                                           emit HookExecutionCompleted
```

---

## 3. Hook Chaining

Hook chaining is the mechanism that allows the output of one hook to feed
directly into the input of the next, all within a single atomic transaction.
This is what makes multi-step strategies like "swap USDC for DAI, then deposit
DAI into a vault" possible without the caller knowing intermediate amounts
ahead of time.

### 3.1 The `USE_PREVIOUS_HOOK_OUTPUT` Sentinel

Every hook defines a constant:

```solidity
uint256 public constant USE_PREVIOUS_HOOK_OUTPUT = type(uint256).max;
```

When the caller sets the amount field (e.g., `amountIn`, `assets`, or `shares`)
to `type(uint256).max`, the hook knows it must resolve the actual amount at
execution time by reading from the previous hook.

### 3.2 The `IHookResult` Interface

```solidity
interface IHookResult {
    function getOutputAmount() external view returns (uint256);
}
```

Every hook that can participate as a *source* in a chain implements
`IHookResult`. The return value depends on the hook:

| Hook | `getOutputAmount()` returns |
|---|---|
| `OneInchSwapHook` | `_swapContext.amountOut` (destination tokens received) |
| `ERC4626ApproveAndDepositHook` | `_depositContext.sharesReceived` (vault shares minted) |
| `ERC4626RedeemHook` | `_redeemContext.assetsReceived` (underlying assets returned) |

### 3.3 The `resolveDynamicAmount` Pattern

When a hook detects `USE_PREVIOUS_HOOK_OUTPUT`, its `buildExecutions` inserts a
`resolveDynamicAmount` call as the *first* execution in its array. At runtime
this function:

1. Calls `IHookResult(previousHook).getOutputAmount()` to read the resolved
   amount.
2. Validates the amount is greater than zero.
3. Stores the amount (and other parameters) into the hook's context struct for
   use by subsequent execution steps.

```
  Hook A (e.g. Swap)                      Hook B (e.g. Deposit)
  ------------------                      ---------------------
  ...                                     resolveDynamicAmount(hookA)
  storeSwapContext (amountOut = 500 DAI)       |
       |                                       v
       +--- getOutputAmount() = 500 -------> _depositContext.assetsDeposited = 500
                                            approveForDeposit(vault)
                                            executeDeposit(receiver)
```

### 3.4 Chaining Example: Swap then Deposit

```solidity
IHookExecution.HookExecution[] memory chain = new IHookExecution.HookExecution[](2);

// Step 1: Swap USDC -> DAI via 1inch
chain[0] = IHookExecution.HookExecution({
    hookId: keccak256("hook.oneinch.swap"),
    data: abi.encode(OneInchSwapHook.SwapData({
        router:       ONEINCH_ROUTER,
        srcToken:     USDC,
        dstToken:     DAI,
        amountIn:     1000e6,                    // 1000 USDC
        minAmountOut: 990e18,                    // slippage protection
        receiver:     address(depositHook),      // DAI goes to the deposit hook
        value:        0,
        swapCalldata: preBuiltSwapCalldata
    }))
});

// Step 2: Deposit all received DAI into vault (dynamic amount)
chain[1] = IHookExecution.HookExecution({
    hookId: keccak256("hook.erc4626.deposit"),
    data: abi.encode(ERC4626ApproveAndDepositHook.ApproveAndDepositData({
        vault:     DAI_VAULT,
        assets:    type(uint256).max,            // USE_PREVIOUS_HOOK_OUTPUT
        receiver:  address(wallet),
        minShares: 980e18                        // slippage protection
    }))
});

wallet.executeWithHookExecution(chain);
```

At execution time, the deposit hook reads the swap hook's `getOutputAmount()`
to know exactly how much DAI was received, then deposits that full amount.

---

## 4. ERC4626ApproveAndDepositHook

**Source**: `src/hooks/ERC4626ApproveAndDepositHook.sol`

### Purpose

Invest underlying assets into an external ERC-4626 vault. This is classified
as an *INFLOW* hook because it increases the wallet's vault-share balance.

### Input Data

```solidity
struct ApproveAndDepositData {
    address vault;       // The ERC-4626 vault to deposit into
    uint256 assets;      // Amount of underlying to deposit (or USE_PREVIOUS_HOOK_OUTPUT)
    address receiver;    // Address that receives the minted shares
    uint256 minShares;   // Minimum acceptable shares (0 to skip validation)
}
```

### Context Struct

```solidity
struct DepositContext {
    address vault;             // Vault deposited into
    address asset;             // Underlying asset address
    uint256 assetsDeposited;   // Amount of assets deposited
    uint256 sharesReceived;    // Shares minted by the vault
    address receiver;          // Who received the shares
    uint256 timestamp;         // Block timestamp of the deposit
}
```

`getOutputAmount()` returns `sharesReceived`.

### Static Flow (known amount)

When `assets` is a concrete value (not `type(uint256).max`):

```
  Execution Index   Target          Action
  ---------------   ------          ------
  [0]               asset token     transfer(hook, assets)
  [1]               hook            approveForDepositStatic(asset, vault, assets)
  [2]               hook            executeDepositStatic(vault, assets, receiver)
  [3]               hook            storeDepositContextStatic(vault, asset, assets, receiver)
  [4] (optional)    hook            validateMinShares(minShares)
```

```
  Wallet                Hook                    Vault
    |                     |                       |
    |-- transfer(assets)->|                       |
    |                     |-- approve(vault) ---->|
    |                     |-- deposit(assets) --->|
    |                     |     <-- shares -------|
    |                     |-- storeContext ------->|  (internal)
    |                     |-- validateMinShares ->|  (view, reverts on fail)
    |                     |                       |
```

The static flow transfers the underlying asset from the wallet to the hook
first, then the hook approves the vault and calls `deposit`. The shares
received value is captured directly from the vault's `deposit` return value
via `executeDepositStatic`, and `storeDepositContextStatic` writes the full
context struct (preserving the already-stored `sharesReceived`).

### Dynamic Flow (amount from previous hook)

When `assets == USE_PREVIOUS_HOOK_OUTPUT`:

```
  Execution Index   Target          Action
  ---------------   ------          ------
  [0]               hook            resolveDynamicAmount(previousHook, vault, asset)
  [1]               hook            approveForDeposit(vault)
  [2]               hook            executeDeposit(receiver)
  [3] (optional)    hook            validateMinShares(minShares)
```

```
  Previous Hook        This Hook                    Vault
       |                   |                           |
       |<- getOutputAmount-|                           |
       |--- amount ------->|                           |
       |                   |-- approve(vault, amt) --->|
       |                   |-- deposit(amt, recv) ---->|
       |                   |     <-- shares -----------|
       |                   |-- validateMinShares ----->|  (view)
       |                   |                           |
```

In the dynamic flow there is no explicit `transfer` step -- the hook already
holds the tokens (received as the `receiver` of the previous hook's operation).
`resolveDynamicAmount` calls `IHookResult(previousHook).getOutputAmount()` and
populates the `_depositContext` with the resolved amount. Subsequent steps
(`approveForDeposit`, `executeDeposit`) read from that context.

### Slippage Protection

Set `minShares > 0` to append a `validateMinShares` execution that reverts with
`HOOK4626DEPOSIT_INSUFFICIENT_SHARES` ("H4D4") if the vault minted fewer shares
than expected.

---

## 5. ERC4626RedeemHook

**Source**: `src/hooks/ERC4626RedeemHook.sol`

### Purpose

Divest from an external ERC-4626 vault by redeeming shares for underlying
assets. This is classified as an *OUTFLOW* hook because it decreases the
wallet's vault-share balance.

### Input Data

```solidity
struct RedeemData {
    address vault;       // The ERC-4626 vault to redeem from
    uint256 shares;      // Number of shares to redeem (or USE_PREVIOUS_HOOK_OUTPUT)
    address receiver;    // Address that receives the underlying assets
    address owner;       // Owner of the shares being redeemed
    uint256 minAssets;   // Minimum acceptable assets (0 to skip validation)
}
```

### Context Struct

```solidity
struct RedeemContext {
    address vault;             // Vault redeemed from
    address asset;             // Underlying asset address
    uint256 sharesRedeemed;    // Number of shares burned
    uint256 assetsReceived;    // Amount of underlying assets received
    address receiver;          // Who received the assets
    address owner;             // Who owned the shares
    uint256 timestamp;         // Block timestamp of the redemption
}
```

`getOutputAmount()` returns `assetsReceived`.

### Static Flow (known amount)

When `shares` is a concrete value:

```
  Execution Index   Target          Action
  ---------------   ------          ------
  [0]               hook            snapshotBalance(asset, receiver)
  [1]               vault           redeem(shares, receiver, owner)
  [2]               hook            storeRedeemContextStatic(vault, asset, shares, receiver, owner)
  [3] (optional)    hook            validateMinAssets(minAssets)
```

```
  Wallet                Hook                    Vault
    |                     |                       |
    |                     |-- snapshotBalance ---->|  (reads balanceOf)
    |-- redeem(shares) ---|---------------------->|
    |                     |     <-- assets -------|
    |                     |-- storeContext ------->|  (balance delta)
    |                     |-- validateMinAssets ->|  (view, reverts on fail)
    |                     |                       |
```

The static flow calls `vault.redeem` directly from the wallet (the execution
target is the vault, not the hook). The hook measures the actual assets
received via **balance-delta tracking**: it snapshots the receiver's asset
balance before the redeem (`snapshotBalance`), then after the redeem,
`storeRedeemContextStatic` computes:

```solidity
assetsReceived = IERC20(asset).balanceOf(receiver) - _preActionBalance;
```

This approach is more reliable than trusting the vault's return value, as it
captures the actual token movement.

### Dynamic Flow (amount from previous hook)

When `shares == USE_PREVIOUS_HOOK_OUTPUT`:

```
  Execution Index   Target          Action
  ---------------   ------          ------
  [0]               hook            resolveDynamicAmount(previousHook, vault, asset, owner)
  [1]               vault           approve(hook, USE_PREVIOUS_HOOK_OUTPUT)
  [2]               hook            executeRedeem(receiver)
  [3]               vault           approve(hook, 0)
  [4] (optional)    hook            validateMinAssets(minAssets)
```

```
  Previous Hook        Wallet / Vault              This Hook
       |                     |                         |
       |<-- getOutputAmount--|                         |
       |--- amount --------->|                         |
       |                     |-- approve(hook, max) -->|
       |                     |                         |-- redeem(shares, recv, owner)
       |                     |                         |     <-- assets
       |                     |-- approve(hook, 0) ---->|  (reset)
       |                     |                         |-- validateMinAssets
       |                     |                         |
```

In the dynamic flow, the wallet approves the hook to spend its vault shares
(since the hook needs to call `vault.redeem` on the wallet's behalf). After
the redeem completes, the approval is immediately reset to zero for security.

### Slippage Protection

Set `minAssets > 0` to append a `validateMinAssets` execution that reverts with
`HOOK4626REDEEM_INSUFFICIENT_ASSETS` ("H4R4") if the vault returned fewer
assets than expected.

---

## 6. OneInchSwapHook

**Source**: `src/hooks/OneInchSwapHook.sol`

### Purpose

Execute token swaps via the 1inch Aggregation Router. Supports both ERC-20 to
ERC-20 swaps and native ETH swaps.

### Input Data

```solidity
struct SwapData {
    address router;        // 1inch aggregation router address (must be whitelisted)
    address srcToken;      // Source token to swap from
    address dstToken;      // Destination token to swap to
    uint256 amountIn;      // Amount to swap (or USE_PREVIOUS_HOOK_OUTPUT)
    uint256 minAmountOut;  // Minimum output (0 to skip validation)
    address receiver;      // Address that receives the swapped tokens
    uint256 value;         // ETH value for native-ETH swaps
    bytes   swapCalldata;  // Pre-built 1inch router calldata
}
```

### Context Struct

```solidity
struct SwapContext {
    address srcToken;      // Source token
    address dstToken;      // Destination token
    uint256 amountIn;      // Amount of source tokens consumed
    uint256 amountOut;     // Amount of destination tokens received
    address receiver;      // Who received the output
    uint256 timestamp;     // Block timestamp
}
```

`getOutputAmount()` returns `amountOut`.

### Static Flow -- ERC-20 Swap

When `srcToken` is an ERC-20 and `amountIn` is a concrete value:

```
  Execution Index   Target          Action
  ---------------   ------          ------
  [0]               srcToken        approve(router, amountIn)
  [1]               hook            snapshotDstBalance(dstToken, receiver)
  [2]               router          swap(calldata)                     {value}
  [3]               srcToken        approve(router, 0)                 (reset)
  [4]               hook            storeSwapContextStatic(src, dst, amountIn, receiver)
  [5] (optional)    hook            validateMinOutput(minAmountOut)
```

```
  Wallet           srcToken        Router          Hook
    |                 |               |               |
    |-- approve ----->|               |               |
    |                 |               |               |-- snapshot dstBalance
    |-- swap calldata |------------->|               |
    |                 |<-- pull ------|               |
    |                 |               |-- dstToken -->| (to receiver)
    |-- approve(0) -->|               |               |
    |                 |               |               |-- storeContext (delta)
    |                 |               |               |-- validateMinOutput
```

### Static Flow -- Native ETH Swap

When `srcToken == NATIVE_ETH` (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`):

```
  Execution Index   Target          Action
  ---------------   ------          ------
  [0]               hook            snapshotDstBalance(dstToken, receiver)
  [1]               router          swap(calldata)                     {value: ETH amount}
  [2]               hook            storeSwapContextStatic(src, dst, amountIn, receiver)
  [3] (optional)    hook            validateMinOutput(minAmountOut)
```

No `approve` or `resetApproval` steps are needed for native ETH.

### Dynamic Flow

When `amountIn == USE_PREVIOUS_HOOK_OUTPUT`:

```
  Execution Index   Target          Action
  ---------------   ------          ------
  [0]               hook            resolveDynamicAmount(previousHook, router, src, dst, value, calldata)
  [1]               hook            approveForSwap(router)
  [2]               hook            executeSwap(receiver)
  [3]               hook            resetSwapApproval()
  [4] (optional)    hook            validateMinOutput(minAmountOut)
```

```
  Previous Hook        This Hook                    Router
       |                   |                           |
       |<- getOutputAmount-|                           |
       |--- amount ------->|                           |
       |                   |-- approve(router, amt) -->|
       |                   |   snapshot dstBalance     |
       |                   |-- call(calldata) -------->|
       |                   |     <-- dstTokens --------|
       |                   |-- approve(router, 0) ---->|  (reset)
       |                   |-- validateMinOutput ----->|  (view)
       |                   |                           |
```

In the dynamic flow, `resolveDynamicAmount` stores the router address, ETH
value, and swap calldata into temporary storage (`_tempRouter`, `_tempValue`,
`_tempSwapCalldata`). The `executeSwap` function reads these values and
performs the low-level `router.call{value}(calldata)`. Balance-delta tracking
measures the actual output amount.

### Router Whitelist

The hook maintains a mapping of allowed routers:

```solidity
mapping(address => bool) private _allowedRouters;
```

Only the contract owner can modify the whitelist:

```solidity
swapHook.setRouterAllowed(ONEINCH_V6_ROUTER, true);
```

Both `buildExecutions` (at build time) and `executeSwap` (at execution time)
check that the router is allowed, providing defense-in-depth.

### Native ETH Support

The sentinel address `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` is used by
1inch to represent native ETH. When `srcToken` equals this sentinel:

- The approval step is skipped (ETH needs no ERC-20 approval).
- The reset-approval step is skipped.
- The `value` field in `SwapData` carries the ETH amount to forward.

---

## 7. Security Patterns

The hook system implements several defense-in-depth patterns that every custom
hook should replicate.

### 7.1 Approval Reset After External Calls

Every hook that grants an ERC-20 approval to an external contract (router,
vault) immediately resets the approval to zero after the operation completes.
This prevents a compromised or malicious external contract from draining
residual allowances in future transactions.

```
  approve(router, amountIn)    -- grant exact approval
  router.swap(...)             -- external call
  approve(router, 0)           -- reset to zero
```

In dynamic flows, dedicated `resetSwapApproval()` / `approve(hook, 0)` steps
handle the reset.

### 7.2 Balance-Delta Tracking

Hooks do not blindly trust return values from external protocols. Instead, they
measure actual token movements using the balance-delta pattern:

```solidity
uint256 balBefore = IERC20(token).balanceOf(account);
// ... perform external operation ...
uint256 received = IERC20(token).balanceOf(account) - balBefore;
```

This protects against:

- Vaults or routers that return incorrect values
- Fee-on-transfer tokens where the actual received amount differs from the
  nominal amount
- Re-entrancy attacks that manipulate reported return values

Used in: `OneInchSwapHook.storeSwapContextStatic`, `OneInchSwapHook.executeSwap`,
`ERC4626RedeemHook.storeRedeemContextStatic`.

### 7.3 Router Whitelisting

The `OneInchSwapHook` does not allow arbitrary addresses as swap targets.
Routers must be explicitly whitelisted by the owner. The check occurs both at
build time (`buildExecutions`) and at execution time (`executeSwap`), so a
router cannot be de-listed between build and execution to bypass the check,
and a malicious `SwapData` cannot specify an attacker-controlled contract.

### 7.4 Slippage Protection

Every hook supports an optional minimum-output check:

| Hook | Parameter | Error Code |
|---|---|---|
| `ERC4626ApproveAndDepositHook` | `minShares` | `H4D4` |
| `ERC4626RedeemHook` | `minAssets` | `H4R4` |
| `OneInchSwapHook` | `minAmountOut` | `H1I3` |

Setting the parameter to `0` skips the validation step entirely (one fewer
execution in the chain). Setting it to a non-zero value appends a `view`
execution that reverts the entire transaction if the output falls short.

### 7.5 Context Cleanup

`finalizeHookContext()` deletes all transient state after execution:

```solidity
// OneInchSwapHook
function finalizeHookContext() external override onlyOwner {
    _executionContext = false;
    delete _swapContext;
    delete _tempRouter;
    delete _tempValue;
    delete _tempSwapCalldata;
    delete _preSwapDstBalance;
}
```

This prevents stale context from leaking into future executions and reclaims
gas via storage refunds.

### 7.6 Access Control

Every hook function that mutates state is protected with `onlyOwner` (Solady).
The owner is the MetaWallet smart account itself, which means only the wallet
(through its execution pipeline) can invoke hook operations. External callers
cannot directly trigger `resolveDynamicAmount`, `executeSwap`, or any context
management function.

---

## 8. Creating Custom Hooks

To add a new strategy operation to the MetaWallet system, implement a contract
that satisfies `IHook` and optionally `IHookResult`.

### Step 1: Implement `IHook`

```solidity
import { IHook } from "metawallet/src/interfaces/IHook.sol";
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

contract MyCustomHook is IHook, Ownable {

    /// @inheritdoc IHook
    function buildExecutions(
        address _previousHook,
        bytes calldata _data
    )
        external
        view
        override
        onlyOwner
        returns (Execution[] memory _executions)
    {
        // 1. Decode your hook-specific data struct from _data
        // 2. Validate inputs (revert on bad data)
        // 3. Check if dynamic amount: yourStruct.amount == USE_PREVIOUS_HOOK_OUTPUT
        // 4. Build and return the Execution[] array
    }

    /// @inheritdoc IHook
    function initializeHookContext() external override onlyOwner {
        _executionContext = true;
    }

    /// @inheritdoc IHook
    function finalizeHookContext() external override onlyOwner {
        _executionContext = false;
        // DELETE all context structs and temporary storage
    }
}
```

### Step 2: Implement `IHookResult` (if chainable)

If your hook produces an output that downstream hooks might consume, implement
`IHookResult`:

```solidity
import { IHookResult } from "metawallet/src/interfaces/IHookResult.sol";

contract MyCustomHook is IHook, IHookResult, Ownable {

    /// @inheritdoc IHookResult
    function getOutputAmount() external view override returns (uint256) {
        return _myContext.outputAmount;
    }
}
```

### Step 3: Follow the Execution Patterns

Structure your `buildExecutions` to follow the established patterns:

**Static flow** (known amount):
```
[pre-action setup] -> [external call] -> [store context] -> [(optional) validate]
```

**Dynamic flow** (amount from previous hook):
```
[resolveDynamicAmount] -> [approve] -> [execute] -> [reset approval] -> [(optional) validate]
```

### Step 4: Apply Security Patterns

Checklist for every custom hook:

- [ ] All state-mutating functions are `onlyOwner`
- [ ] Approvals are reset to zero after every external call
- [ ] Output amounts are measured via balance-delta, not return values alone
- [ ] External targets are validated (whitelisted if applicable)
- [ ] Slippage protection is available via an optional validation step
- [ ] `finalizeHookContext` deletes ALL transient storage
- [ ] Input data is fully validated in `buildExecutions` (no zero addresses,
      no zero amounts unless dynamic, no empty calldata)

### Step 5: Install and Test

```solidity
// Install
bytes32 hookId = keccak256("my.custom.hook");
wallet.installHook(hookId, address(myHook));

// Execute
IHookExecution.HookExecution[] memory chain = new IHookExecution.HookExecution[](1);
chain[0] = IHookExecution.HookExecution({
    hookId: hookId,
    data: abi.encode(MyCustomHook.MyData({
        // ...
    }))
});
wallet.executeWithHookExecution(chain);
```

### Error Codes Reference

| Prefix | Contract | Codes |
|--------|----------|-------|
| `HE` | `HookExecution` | HE1 (invalid address), HE2 (already installed), HE3 (not installed), HE4 (empty chain) |
| `H4D` | `ERC4626ApproveAndDepositHook` | H4D1 (invalid data), H4D4 (insufficient shares), H4D6 (no previous hook) |
| `H4R` | `ERC4626RedeemHook` | H4R1 (invalid data), H4R4 (insufficient assets), H4R6 (no previous output) |
| `H1I` | `OneInchSwapHook` | H1I1 (invalid data), H1I2 (no previous hook), H1I3 (insufficient output), H1I4 (invalid router), H1I5 (router not allowed) |
