# MetaWallet Architecture

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Inheritance Architecture](#2-inheritance-architecture)
3. [Vault Module (ERC-7540)](#3-vault-module-erc-7540)
4. [Hook System](#4-hook-system)
5. [Accounting Model](#5-accounting-model)
6. [Security Architecture](#6-security-architecture)
7. [Storage Pattern](#7-storage-pattern)
8. [Execution Flow](#8-execution-flow)

---

## 1. System Overview

MetaWallet is a hybrid smart wallet that merges a minimal smart account with an ERC-7540 asynchronous tokenized vault. It is designed for institutional fund managers who need to:

- Operate a tokenized vault that accepts deposits and redemptions from whitelisted investors.
- Deploy the vault's idle capital into external DeFi strategies (lending protocols, liquidity pools, yield vaults) through composable hook chains.
- Maintain accurate on-chain accounting of both idle and deployed assets without manual share-price manipulation.

The core insight is that a vault and the wallet that manages its capital are the same contract. Instead of a vault holding assets and a separate EOA or multisig deploying them, MetaWallet unifies both roles into a single on-chain entity. The wallet **is** the vault, and the vault **is** the wallet.

```
+--------------------------------------------------------------------+
|                           MetaWallet                               |
|                                                                    |
|  +---------------------+  +------------------+  +---------------+  |
|  | MinimalSmartAccount |  |  HookExecution   |  | MultiFacetProxy| |
|  | (execution engine,  |  |  (hook chain     |  | (delegates to  | |
|  |  roles, registry,   |  |   orchestrator)  |  |  VaultModule)  | |
|  |  UUPS upgrade)      |  |                  |  |                | |
|  +---------------------+  +------------------+  +---------------+  |
|                                                                    |
|  Installed Hooks (external contracts):                             |
|  +----------------+  +-------------------------+  +--------------+ |
|  | OneInchSwapHook|  | ERC4626ApproveAndDeposit|  | ERC4626Redeem| |
|  +----------------+  +-------------------------+  +--------------+ |
|                                                                    |
|  Facet Module (delegatecall target):                               |
|  +---------------------------------------------------------------+ |
|  |                     VaultModule (ERC-7540)                     | |
|  |  ERC20 shares | async deposit/redeem | settlement | merkle    | |
|  +---------------------------------------------------------------+ |
+--------------------------------------------------------------------+
```

---

## 2. Inheritance Architecture

MetaWallet inherits from three base contracts, each providing a distinct capability layer.

```
                    +-------------------+
                    |    MetaWallet     |
                    +-------------------+
                           /  |  \
                          /   |   \
                         /    |    \
    +--------------------+    |    +------------------+
    | MinimalSmartAccount|    |    | MultiFacetProxy  |
    | (contract)         |    |    | (abstract)       |
    +--------------------+    |    +------------------+
    | - OwnableRoles     |    |    | - Proxy (OZ)     |
    | - UUPSUpgradeable  |    |    | - selector->impl |
    | - Initializable    |    |    |   mapping        |
    | - IRegistry auth   |    |    +------------------+
    | - execute()        |    |
    | - _authorizeExecute|    |
    +--------------------+    |
                              |
                   +-------------------+
                   |   HookExecution   |
                   |   (abstract)      |
                   +-------------------+
                   | - hook registry   |
                   | - build chain     |
                   | - process chain   |
                   | - ERC-7201 storage|
                   +-------------------+
```

### 2.1 MinimalSmartAccount

Source: `dependencies/minimal-smart-account-1.0/src/MinimalSmartAccount.sol`

Provides the core smart-account execution engine:

| Feature | Detail |
|---|---|
| **Role-based access** | Inherits Solady `OwnableRoles`. Defines `ADMIN_ROLE` (`_ROLE_0`) and `EXECUTOR_ROLE` (`_ROLE_1`). |
| **Batch execution** | `execute(ModeCode, bytes)` supports `CALLTYPE_BATCH` with `EXECTYPE_DEFAULT` (revert-on-failure) and `EXECTYPE_TRY` (continue-on-failure). |
| **Registry authorization** | Every external call passes through `IRegistry.authorizeCall(target, selector, params)` before execution. |
| **UUPS upgradeability** | Owner-gated upgrade path via `UUPSUpgradeable`. |
| **Token receivers** | Supports receiving ETH, ERC-721, and ERC-1155 tokens natively. |
| **ERC-7201 storage** | `MinimalAccountStorage` (registry, nonce, accountId) stored at a deterministic slot. |

### 2.2 HookExecution

Source: `src/HookExecution.sol`

An abstract contract that adds multi-hook orchestration capabilities. MetaWallet overrides `_executeOperations` to wire hook-built executions through the MinimalSmartAccount's registry-authorized execution path.

Key responsibilities:
- Maintains a registry of installed hooks (`mapping(bytes32 => address)`) with an enumerable set of hook IDs.
- Builds a flattened execution chain from multiple hooks in a single pass.
- Manages the three-phase hook lifecycle: `initializeHookContext` -> execute -> `finalizeHookContext`.

### 2.3 MultiFacetProxy

Source: `dependencies/kam-1.0/src/base/MultiFacetProxy.sol`

A selector-based proxy (similar to EIP-2535 Diamond, but simplified) that maps `bytes4` function selectors to implementation contract addresses. When a call arrives whose selector is not defined on MetaWallet itself, the Solidity `fallback()` inherited from OpenZeppelin's `Proxy` triggers `_implementation()`, which looks up the target in the `selectorToImplementation` mapping and performs a `delegatecall`.

This is how the VaultModule's 44 function selectors (ERC-20, ERC-4626, ERC-7540, settlement, pause, etc.) are exposed on the MetaWallet address without bloating the main contract.

---

## 3. Vault Module (ERC-7540)

Source: `src/modules/VaultModule.sol`

### 3.1 Installation as a Facet

VaultModule is deployed as a standalone contract and then "installed" into MetaWallet by calling `addFunctions(selectors, vaultModuleAddress, false)`. The module exposes its 44 selectors via the `selectors()` function (implementing `IModule`). After installation, any call to these selectors on the MetaWallet proxy address is delegatecalled into VaultModule, executing against MetaWallet's storage.

### 3.2 Inheritance Chain

```
VaultModule
  |-- ERC7540 (async deposit/redeem layer)
  |     |-- ERC4626 (Solady -- share math, ERC-20 token)
  |-- OwnableRoles (Solady -- role checks run against MetaWallet's OwnableRoles storage)
  |-- IModule (exposes selectors() for facet registration)
```

### 3.3 Async Deposit Flow (ERC-7540)

```
Investor                    MetaWallet (VaultModule facet)
   |                                    |
   |-- requestDeposit(assets, ctrl, owner) -->|
   |   [WHITELISTED_ROLE required]      |
   |   [transfers assets into vault]    |
   |   [creates pending request]        |
   |   [immediately fulfills request]   |
   |                                    |
   |-- deposit(assets, receiver) ------>|
   |   [mints shares to receiver]       |
   |   [virtualTotalAssets += assets]   |
   |<-- shares -------------------------|
```

The VaultModule's `requestDeposit` immediately calls `_fulfillDepositRequest`, making the flow synchronous in practice while preserving ERC-7540 interface compliance. This allows future upgrades to introduce actual async settlement without changing the external API.

### 3.4 Async Redeem Flow (ERC-7540)

```
Investor                    MetaWallet (VaultModule facet)
   |                                    |
   |-- requestRedeem(shares, ctrl, owner) -->|
   |   [transfers shares to vault]      |
   |   [creates pending redeem request] |
   |                                    |
   |   ... (manager fulfills when       |
   |        idle assets available) ...  |
   |                                    |
   |-- redeem(shares, to, controller) ->|
   |   [limited by min(idle, pending)]  |
   |   [burns shares held by vault]     |
   |   [transfers assets to receiver]   |
   |   [virtualTotalAssets -= assets]   |
   |<-- assets -------------------------|
```

Redemptions are gated by `maxRedeem`, which returns the minimum of (a) shares convertible from `totalIdle()` and (b) the controller's pending redeem request. This ensures the vault never sends more assets than it holds in idle.

### 3.5 ERC-7201 Storage

```solidity
struct VaultModuleStorage {
    uint256 virtualTotalAssets;
    bytes32 merkleRoot;
    bool    initialized;
    bool    paused;
    address asset;
    string  name;
    string  symbol;
    uint8   decimals;
    uint256 maxAllowedDelta;
}
// Slot: 0x511216ea87b3ec844059069c7b970c812573d49674957e6b4ccb340e8aff7200
```

---

## 4. Hook System

### 4.1 Core Interfaces

**IHook** -- implemented by every hook contract:

```solidity
interface IHook {
    function buildExecutions(
        address previousHook,
        bytes calldata data
    ) external view returns (Execution[] memory executions);

    function initializeHookContext() external;
    function finalizeHookContext() external;
}
```

**IHookResult** -- implemented by hooks that produce chainable output:

```solidity
interface IHookResult {
    function getOutputAmount() external view returns (uint256);
}
```

### 4.2 Hook Installation

Hooks are installed by an ADMIN via `MetaWallet.installHook(hookId, hookAddress)`. Each hook is registered with a `bytes32` identifier (e.g., `keccak256("hook.oneinch.swap")`) and stored in the `HookExecutionStorage` mapping. The hook contract is an external contract owned by the MetaWallet address, not a facet -- it is called via regular `call`, not `delegatecall`.

### 4.3 Execution Flow

A hook execution request is an array of `HookExecution` structs:

```solidity
struct HookExecution {
    bytes32 hookId;   // identifies which hook to invoke
    bytes   data;     // hook-specific encoded parameters
}
```

The execution proceeds in three phases:

```
Phase 1: BUILD
  for each hook in chain:
    hook.buildExecutions(previousHook, data) -> Execution[]
  flatten all Execution[] arrays into a single Execution[] array

Phase 2: INITIALIZE + EXECUTE
  for each hook: hook.initializeHookContext()
  _executeOperations(allExecutions)
    for each execution:
      registry.authorizeCall(target, selector, params)
      target.call(callData)

Phase 3: FINALIZE
  for each hook: hook.finalizeHookContext()
    (clears all temporary storage)
```

### 4.4 Dynamic Amount Resolution (USE_PREVIOUS_HOOK_OUTPUT)

Hooks support a sentinel value `USE_PREVIOUS_HOOK_OUTPUT = type(uint256).max` that signals the amount should be resolved at execution time from the previous hook's output.

When a hook sees this sentinel during `buildExecutions`, it emits a `resolveDynamicAmount` execution as the first step. At runtime, this call reads `IHookResult(previousHook).getOutputAmount()` and stores the resolved value in the hook's temporary storage for use by subsequent steps.

```
Hook A (1inch Swap)                Hook B (ERC4626 Deposit)
  |                                  |
  | swap USDC -> DAI                 | deposit DAI into Aave vault
  | stores amountOut in context      | amount = USE_PREVIOUS_HOOK_OUTPUT
  |                                  |
  | getOutputAmount() = 1000 DAI <---| resolveDynamicAmount(hookA)
  |                                  | approveForDeposit(vault)
  |                                  | executeDeposit(receiver)
```

### 4.5 Static vs Dynamic Execution Paths

Each hook implements two distinct execution paths:

| Aspect | Static Path | Dynamic Path |
|---|---|---|
| **Amount source** | Provided in calldata at build time | Resolved at runtime from previous hook |
| **Sentinel** | `amountIn > 0 && amountIn != type(uint256).max` | `amountIn == type(uint256).max` |
| **Approve pattern** | Direct ERC-20 approve to target | Hook-mediated approve via `approveForSwap()` / `approveForDeposit()` |
| **Execution** | Direct call to external protocol | Hook-mediated call via `executeSwap()` / `executeDeposit()` |
| **Context storage** | `storeSwapContextStatic()` / `storeDepositContextStatic()` | Stored during `resolveDynamicAmount()` + `execute*()` |

### 4.6 Balance-Delta Tracking Pattern

Hooks use a snapshot-before / delta-after pattern to accurately measure outputs, since many DeFi protocols do not return the actual amount received:

```
1. snapshotDstBalance(token, account)    // store balanceBefore
2. <execute external protocol call>       // actual swap/deposit/redeem
3. amountOut = balanceOf(account) - balanceBefore  // compute delta
```

This pattern is used in:
- `OneInchSwapHook`: `snapshotDstBalance` -> router swap -> `storeSwapContextStatic`
- `ERC4626RedeemHook`: `snapshotBalance` -> vault redeem -> `storeRedeemContextStatic`

### 4.7 Context Cleanup

Every hook clears its temporary storage in `finalizeHookContext()`. This is critical because hooks are long-lived contracts shared across multiple executions. After finalization:

- `_executionContext` is set to `false`
- All context structs are deleted (`_swapContext`, `_depositContext`, `_redeemContext`)
- All temporary storage is cleared (`_tempRouter`, `_tempValue`, `_tempSwapCalldata`, `_preSwapDstBalance`, `_preActionBalance`)

### 4.8 Implemented Hooks

| Hook | Purpose | Input | Output (IHookResult) |
|---|---|---|---|
| `OneInchSwapHook` | Token swap via 1inch Aggregation Router | srcToken + amountIn | amountOut (dstToken received) |
| `ERC4626ApproveAndDepositHook` | Approve + deposit into ERC-4626 vault | asset + amount | sharesReceived |
| `ERC4626RedeemHook` | Redeem shares from ERC-4626 vault | shares + vault | assetsReceived |

---

## 5. Accounting Model

### 5.1 Virtual totalAssets Design

The vault uses a `virtualTotalAssets` counter instead of reading `balanceOf(address(this))` for the underlying asset. This is essential because the wallet deploys capital to external protocols, reducing its actual balance while the deployed assets still back outstanding shares.

```
totalAssets() returns virtualTotalAssets   (NOT balanceOf)
totalIdle()  returns balanceOf(asset) - totalPendingDepositRequests
```

### 5.2 When virtualTotalAssets Changes

| Operation | Effect on virtualTotalAssets | Rationale |
|---|---|---|
| `deposit` / `mint` | **Increases** by deposited assets | New capital enters the vault |
| `redeem` / `withdraw` | **Decreases** by withdrawn assets | Capital leaves the vault |
| Hook execution (invest) | **No change** | Assets move from idle to deployed; total remains the same |
| Hook execution (divest) | **No change** | Assets move from deployed to idle; total remains the same |
| `settleTotalAssets` | **Set to new value** | Reflects yield/loss from deployed strategies |

### 5.3 Share Price Stability During Invest/Divest

When the manager deploys 1000 USDC from idle into an Aave vault via hooks:

```
Before invest:
  virtualTotalAssets = 10,000 USDC
  totalIdle          =  5,000 USDC  (actual balance)
  deployed           =  5,000 USDC  (in strategies)

After invest (deploy 1,000 USDC more):
  virtualTotalAssets = 10,000 USDC  (UNCHANGED)
  totalIdle          =  4,000 USDC  (balance decreased)
  deployed           =  6,000 USDC  (in strategies)

Share price: UNCHANGED -- investors see no impact from capital deployment
```

### 5.4 Settlement

The MANAGER periodically calls `settleTotalAssets(newTotal, merkleRoot)` to update `virtualTotalAssets` based on the actual combined value of idle + deployed assets. This is the only operation that changes the share price.

Settlement includes a delta guard: if `maxAllowedDelta` is set (in basis points), the new total must be within that percentage of the current total. This prevents erroneous or malicious settlement from drastically moving the share price in a single update.

```
deltaGuard:
  deltaBps = |newTotal - currentTotal| * 10000 / currentTotal
  require(deltaBps <= maxAllowedDelta)
```

The `merkleRoot` is a commitment to the breakdown of deployed assets across strategies. Anyone can verify the breakdown by calling `validateTotalAssets(strategies[], values[], merkleRoot)`.

---

## 6. Security Architecture

### 6.1 Role System

MetaWallet uses Solady's `OwnableRoles` for gas-efficient bitmap-based role management.

| Role | Constant | Bit | Purpose |
|---|---|---|---|
| ADMIN | `_ROLE_0` | `1 << 0` | Install/uninstall hooks, install facets, initialize vault, set maxAllowedDelta |
| WHITELISTED | `_ROLE_1` | `1 << 1` | Submit deposit requests (investor whitelist) |
| EXECUTOR | `_ROLE_1` * | `1 << 1` | Execute transactions via `execute()` and `executeWithHookExecution()` |
| MANAGER | `_ROLE_4` | `1 << 4` | Call `settleTotalAssets` to update accounting |
| EMERGENCY_ADMIN | `_ROLE_6` | `1 << 6` | Pause and unpause the vault |

\* Note: In `MinimalSmartAccount`, EXECUTOR_ROLE is `_ROLE_1`. In `VaultModule`, WHITELISTED_ROLE is also `_ROLE_1`. Since VaultModule runs via delegatecall in MetaWallet's storage context, both share the same OwnableRoles bitmap. The EXECUTOR_ROLE and WHITELISTED_ROLE occupy the same bit position, meaning any address granted executor permission is also whitelisted, and vice versa.

### 6.2 Registry Authorization

Every execution -- whether from `execute()` or `executeWithHookExecution()` -- passes through the `IRegistry` contract:

```solidity
_registry.authorizeCall(target, functionSig, params);
```

This external registry acts as a configurable allowlist that validates:
- The target contract address
- The specific function selector being called
- The parameters of the call

This provides defense-in-depth: even if an EXECUTOR is compromised, they can only call pre-approved targets with pre-approved function signatures.

### 6.3 Approval Reset Pattern

All hooks follow a strict pattern of resetting token approvals after external calls:

**OneInchSwapHook (static path):**
```
1. approve(router, amountIn)     // grant exact approval
2. router.swap(...)              // router pulls tokens
3. approve(router, 0)            // RESET approval to zero
```

**OneInchSwapHook (dynamic path):**
```
1. resolveDynamicAmount(...)     // get amount from previous hook
2. approveForSwap(router)       // grant exact approval
3. executeSwap(receiver)        // router pulls tokens
4. resetSwapApproval()           // RESET approval to zero
```

This prevents residual approvals that could be exploited if the router or vault is compromised.

### 6.4 Pause Mechanism

The EMERGENCY_ADMIN can pause the vault at any time:

```solidity
function pause() external { _checkEmergencyAdminRole(); $.paused = true; }
function unpause() external { _checkEmergencyAdminRole(); $.paused = false; }
```

When paused, the following operations are blocked:
- `requestDeposit`
- `deposit` / `mint`
- `redeem` / `withdraw`

Hook executions (invest/divest) are NOT blocked by pause, allowing the manager to unwind positions even during an emergency.

### 6.5 Merkle Validation for External Holdings

To provide transparency over deployed capital, the MANAGER submits a merkle root alongside each settlement. The merkle tree is constructed from `(strategy_address, value)` leaf pairs:

```
leaf[i] = keccak256(abi.encodePacked(strategy_address, value))
```

Anyone can verify the total assets breakdown:

```solidity
validateTotalAssets(strategies, values, merkleRoot) -> bool
```

This creates a verifiable audit trail of where capital is deployed.

### 6.6 Settlement Delta Guard

The `maxAllowedDelta` (in basis points, max 10000 = 100%) bounds how much `virtualTotalAssets` can change in a single settlement call. If set to, say, 500 (5%), a settlement that would move the share price by more than 5% in either direction is rejected. This limits the blast radius of a compromised MANAGER key.

### 6.7 Router Whitelist (1inch)

The `OneInchSwapHook` maintains its own allowlist of router addresses:

```solidity
mapping(address => bool) private _allowedRouters;
```

Only the hook's owner (the MetaWallet) can add or remove routers. Every swap execution validates the router against this whitelist, preventing calls to arbitrary contracts through the swap path.

### 6.8 Hook Ownership

All hook contracts are `Ownable` (Solady) with the MetaWallet as owner. Every mutating function on a hook is gated by `onlyOwner`, ensuring hooks can only be operated by their parent MetaWallet -- not by arbitrary external callers.

---

## 7. Storage Pattern

MetaWallet uses ERC-7201 (namespaced storage) across all contracts to prevent storage collisions in its multi-inheritance and proxy architecture.

### 7.1 Storage Slot Map

| Contract | Namespace | Slot | Contents |
|---|---|---|---|
| `MinimalSmartAccount` | `minimalaccount.storage` | `0x6bd7bb73...3a00` | registry, nonce, accountId |
| `HookExecution` | `metawallet.storage.HookExecution` | `0x84561f58...9100` | hooks mapping, hookIds set |
| `MultiFacetProxy` | `kam.storage.MultiFacetProxy` | `0xfeaf205b...2d00` | selectorToImplementation mapping |
| `VaultModule` | `metawallet.storage.VaultModule` | `0x511216ea...7200` | virtualTotalAssets, merkleRoot, paused, asset, name, symbol, decimals, maxAllowedDelta |
| `ERC7540` | `metawallet.storage.erc7540` | `0x1f258c11...ff00` | pendingDepositRequest, pendingRedeemRequest, claimableDepositRequest, claimableRedeemRequest, isOperator, totalPendingDepositRequests |
| `OwnableRoles` | *(Solady built-in)* | *(Solady slots)* | owner, roles bitmap |
| `ERC4626 / ERC20` | *(Solady built-in)* | *(Solady slots)* | balances, allowances, totalSupply |

### 7.2 Why This Matters

Because VaultModule executes via `delegatecall` from MultiFacetProxy, it writes to MetaWallet's storage. Without namespaced storage, VaultModule's state variables would collide with MetaWallet's own storage. ERC-7201 guarantees each module writes to a deterministic, non-overlapping slot derived from a unique namespace string.

---

## 8. Execution Flow

### 8.1 Step-by-Step: executeWithHookExecution

The following traces a complete hook execution, for example: "Swap 1000 USDC to DAI via 1inch, then deposit the DAI into an Aave vault."

```
Caller (EXECUTOR role)
  |
  | executeWithHookExecution([
  |   { hookId: SWAP_HOOK,    data: encode(SwapData{...}) },
  |   { hookId: DEPOSIT_HOOK, data: encode(DepositData{amount: USE_PREVIOUS_HOOK_OUTPUT, ...}) }
  | ])
  |
  v
MetaWallet.executeWithHookExecution()
  |
  | 1. _authorizeExecute(msg.sender)       // verify EXECUTOR_ROLE
  |
  | 2. _executeHookExecution(hookExecutions)
  |    |
  |    | 2a. _buildExecutionChain(hookExecutions)
  |    |     |
  |    |     | for hook[0] (SWAP_HOOK):
  |    |     |   previousHook = address(0)
  |    |     |   IHook(swapHook).buildExecutions(address(0), swapData)
  |    |     |   -> returns Execution[]:
  |    |     |     [0] approve(router, 1000)
  |    |     |     [1] snapshotDstBalance(DAI, wallet)
  |    |     |     [2] router.swap(...)
  |    |     |     [3] approve(router, 0)
  |    |     |     [4] storeSwapContextStatic(USDC, DAI, 1000, wallet)
  |    |     |     [5] validateMinOutput(minOut)
  |    |     |
  |    |     | for hook[1] (DEPOSIT_HOOK):
  |    |     |   previousHook = swapHook
  |    |     |   IHook(depositHook).buildExecutions(swapHook, depositData)
  |    |     |   -> returns Execution[]:
  |    |     |     [6] resolveDynamicAmount(swapHook, vault, DAI)
  |    |     |     [7] approveForDeposit(vault)
  |    |     |     [8] executeDeposit(receiver)
  |    |     |     [9] validateMinShares(minShares)
  |    |     |
  |    |     | flatten -> allExecutions[0..9]
  |    |
  |    | 2b. _processHookChain(allExecutions, hookExecutions)
  |    |     |
  |    |     | PHASE: INITIALIZE
  |    |     |   swapHook.initializeHookContext()       // _executionContext = true
  |    |     |   depositHook.initializeHookContext()     // _executionContext = true
  |    |     |
  |    |     | PHASE: EXECUTE
  |    |     |   _executeOperations(allExecutions[0..9])
  |    |     |     for each execution[i]:
  |    |     |       registry.authorizeCall(target, sig, params)
  |    |     |       target.call{value}(callData)
  |    |     |       emit Executed(...)
  |    |     |
  |    |     | PHASE: FINALIZE
  |    |     |   swapHook.finalizeHookContext()
  |    |     |     -> delete _swapContext, _tempRouter, etc.
  |    |     |   depositHook.finalizeHookContext()
  |    |     |     -> delete _depositContext
  |    |
  |    | return results
  |
  v
Returns bytes[] results to caller
```

### 8.2 Registry Authorization Per Call

Within `_executeOperations`, MetaWallet overrides MinimalSmartAccount's default `_exec` to handle `memory` (not `calldata`) execution arrays produced by the hook build phase. For each execution, it:

1. Extracts the 4-byte function selector via assembly.
2. Extracts the remaining calldata as params.
3. Calls `registry.authorizeCall(target, functionSig, params)`.
4. If authorized, calls `target.call{value}(callData)`.
5. Increments the nonce and emits `Executed`.

This means every single sub-operation within a hook chain -- approvals, swaps, deposits, context management calls -- is individually authorized by the external registry.

### 8.3 Error Codes

All errors use short string codes with contract-specific prefixes for efficient debugging:

| Prefix | Contract | Codes |
|---|---|---|
| `HE` | HookExecution | HE1 (invalid address), HE2 (already installed), HE3 (not installed), HE4 (empty chain) |
| `VM` | VaultModule | VM1 (already initialized), VM2 (invalid decimals), VM3 (paused), VM4 (mismatched arrays), VM5 (delta exceeds max), VM6 (invalid BPS) |
| `H4D` | ERC4626ApproveAndDepositHook | H4D1 (invalid data), H4D4 (insufficient shares), H4D6 (no previous hook) |
| `H4R` | ERC4626RedeemHook | H4R1 (invalid data), H4R4 (insufficient assets), H4R6 (no previous output) |
| `H1I` | OneInchSwapHook | H1I1 (invalid data), H1I2 (no previous hook), H1I3 (insufficient output), H1I4 (invalid router), H1I5 (router not allowed) |
