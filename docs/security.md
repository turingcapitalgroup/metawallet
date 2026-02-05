# Security Considerations

This document covers the security architecture, access control model, trust assumptions, and error reference for MetaWallet.

---

## 1. Role-Based Access Control

MetaWallet uses Solady's `OwnableRoles` for role management. Roles are bitmask-based, where each role corresponds to a specific bit position.

### Role Table

| Role | Constant | Slot | Bitmask Value | Description |
|------|----------|------|---------------|-------------|
| Admin | `ADMIN_ROLE` | `_ROLE_0` | 1 | Full administrative control |
| Whitelisted | `WHITELISTED_ROLE` | `_ROLE_1` | 2 | Deposit access (requestDeposit) |
| Manager | `MANAGER_ROLE` | `_ROLE_4` | 16 | Settlement operations |
| Emergency Admin | `EMERGENCY_ADMIN_ROLE` | `_ROLE_6` | 64 | Pause/unpause vault |

### Role Permissions

**ADMIN_ROLE (`_ROLE_0 = 1`)**
- Install and uninstall hooks (`installHook`, `uninstallHook`)
- Add and remove modules via `MultiFacetProxy`
- Initialize the vault (`initializeVault`)
- Set the maximum allowed settlement delta (`setMaxAllowedDelta`)

**WHITELISTED_ROLE (`_ROLE_1 = 2`)**
- Call `requestDeposit` on the vault
- This role controls who can initiate deposits into the vault

**MANAGER_ROLE (`_ROLE_4 = 16`)**
- Settle total assets and update the merkle root (`settleTotalAssets`)
- This is the only role that can modify the share price

**EMERGENCY_ADMIN_ROLE (`_ROLE_6 = 64`)**
- Pause the vault (`pause`)
- Unpause the vault (`unpause`)

### Role Overlap: WHITELISTED and EXECUTOR

`WHITELISTED_ROLE` and `EXECUTOR_ROLE` (from `MinimalSmartAccount`) both map to `_ROLE_1`. Since Solady roles are bitmask-based, granting one automatically grants the other. This means:

- Any address whitelisted for deposits can also execute wallet operations via `executeWithHookExecution`.
- Any executor can also call `requestDeposit`.

This is a deliberate design decision. Operators interacting with the system need both capabilities: submitting deposits on behalf of users and executing strategy operations.

---

## 2. Registry Authorization

Every execution that passes through `_executeOperations` is subject to registry authorization. This provides a defense-in-depth layer independent of role checks.

### Flow

```
executeWithHookExecution(hookExecutions)
  -> _authorizeExecute(msg.sender)         // Role check (EXECUTOR_ROLE)
  -> _executeHookExecution(hookExecutions)
    -> _executeOperations(executions)
      -> for each execution:
           1. Extract selector (first 4 bytes of callData)
           2. Extract params (remaining bytes after selector)
           3. registry.authorizeCall(target, selector, params)
           4. target.callContract(value, callData)
```

### Selector and Params Extraction

The `_executeOperations` function uses inline assembly to efficiently extract the function selector and parameters from the callData:

- **Selector**: Read 4 bytes from `callData[0:4]` via `mload(add(_callData, 32))`
- **Params**: Copy `callData[4:]` into a new bytes array using a word-by-word copy loop with masking for the final partial word

### Defense-in-Depth

Even if an address holds `EXECUTOR_ROLE` (`_ROLE_1`), every individual call must be explicitly authorized by the registry. The registry can enforce:

- Which target contracts are callable
- Which function selectors are allowed per target
- Parameter-level restrictions (e.g., limiting amounts, whitelisting addresses)

This means a compromised executor cannot make arbitrary calls -- only those pre-approved by the registry administrator.

---

## 3. Virtual Accounting Security

### Inflation / Donation Attack Prevention

MetaWallet uses `virtualTotalAssets` instead of `asset.balanceOf(address(this))` for its `totalAssets()` return value. This design prevents the classic ERC-4626 inflation/donation attack:

- **Attack vector**: An attacker donates tokens directly to the vault contract, inflating `balanceOf` relative to `totalSupply`, which manipulates the share price.
- **Mitigation**: Since `totalAssets()` returns `virtualTotalAssets` (a stored value), direct token donations have no effect on share price calculations. The value only changes through:
  1. `deposit` / `mint` -- increases by the deposited asset amount
  2. `redeem` / `withdraw` -- decreases by the withdrawn asset amount
  3. `settleTotalAssets` -- explicit manager update (subject to delta guard)

### Settlement Delta Guard

The `maxAllowedDelta` parameter (in basis points, where 10000 = 100%) limits how much the manager can change `virtualTotalAssets` in a single settlement:

```solidity
uint256 _deltaBps = (_delta * BPS_DENOMINATOR) / _currentTotalAssets;
require(_deltaBps <= _maxDelta, VAULTMODULE_DELTA_EXCEEDS_MAX);
```

Key properties:
- Set by `ADMIN_ROLE` via `setMaxAllowedDelta`
- When `maxAllowedDelta = 0`, the guard is disabled (no limit)
- When `currentTotalAssets = 0`, the guard is bypassed (division by zero protection)
- Prevents a compromised or malicious manager from drastically altering the share price in a single transaction

### Merkle Root Attestation

Each settlement includes a merkle root that attests to the distribution of external holdings across strategies. This allows:

- Off-chain verification of reported `totalAssets` against actual strategy positions
- Anyone can call `validateTotalAssets(strategies, values, merkleRoot)` to verify the breakdown
- The merkle root is computed from `keccak256(abi.encodePacked(strategyAddress, value))` leaf pairs

---

## 4. Hook Security

### Ownership Model

All hooks inherit Solady's `Ownable` with `owner = MetaWallet`. Every mutating function on hooks is protected by `onlyOwner`, meaning only the MetaWallet contract itself can call hook functions. This prevents:

- External actors from directly calling `initializeHookContext`, `finalizeHookContext`, or any execution function
- Other contracts from manipulating hook state during execution

### Approval Reset Pattern

Hooks follow a strict approve-use-reset pattern to minimize token approval exposure:

**ERC4626ApproveAndDepositHook (static flow)**:
1. `safeApproveWithRetry(vault, amount)` -- approve exact amount
2. `vault.deposit(assets, receiver)` -- vault pulls tokens
3. No explicit reset needed (exact amount consumed)

**ERC4626RedeemHook (dynamic flow)**:
1. `vault.approve(hook, USE_PREVIOUS_HOOK_OUTPUT)` -- MetaWallet approves hook
2. `vault.redeem(shares, receiver, owner)` -- hook redeems shares
3. `vault.approve(hook, 0)` -- reset approval to zero

**OneInchSwapHook (static flow)**:
1. `srcToken.approve(router, amountIn)` -- approve exact amount
2. Router executes swap (pulls tokens)
3. `srcToken.approve(router, 0)` -- reset approval to zero

**OneInchSwapHook (dynamic flow)**:
1. `safeApproveWithRetry(router, amountIn)` -- approve resolved amount
2. Router executes swap
3. `resetSwapApproval()` -- sets approval back to zero

### Balance-Delta Tracking

Hooks do not trust return values from external protocol calls for determining actual amounts received. Instead, they use a snapshot-delta pattern:

1. **Snapshot**: Record the receiver's token balance before the operation (`snapshotBalance` / `snapshotDstBalance`)
2. **Execute**: Perform the external call (deposit, redeem, swap)
3. **Delta**: Compute `balanceAfter - balanceBefore` to determine actual tokens received

This protects against protocols that return incorrect values or have fee-on-transfer mechanics.

### Router Whitelist

The `OneInchSwapHook` maintains a whitelist of allowed router addresses (`_allowedRouters` mapping). Validation occurs at two points:

1. **Build time**: `buildExecutions` checks `_allowedRouters[router]` before constructing the execution array
2. **Execution time**: `executeSwap` re-checks `_allowedRouters[router]` before making the low-level call

Only the hook owner (MetaWallet) can modify the whitelist via `setRouterAllowed`.

### Slippage Protection

Each hook provides configurable slippage protection:

| Hook | Parameter | Validation Function |
|------|-----------|-------------------|
| `ERC4626ApproveAndDepositHook` | `minShares` | `validateMinShares(minShares)` |
| `ERC4626RedeemHook` | `minAssets` | `validateMinAssets(minAssets)` |
| `OneInchSwapHook` | `minAmountOut` | `validateMinOutput(minAmountOut)` |

Validation is added as an optional execution step at the end of each hook's execution chain. When the minimum is set to `0`, the validation step is omitted entirely.

### Context Cleanup

After every hook chain execution, `finalizeHookContext()` is called on each hook, which:

1. Sets `_executionContext = false`
2. Deletes all stored context data (`delete _depositContext`, `delete _redeemContext`, `delete _swapContext`)
3. Deletes temporary storage (`delete _tempRouter`, `delete _tempValue`, `delete _tempSwapCalldata`, `delete _preSwapDstBalance`, `delete _preActionBalance`)

This ensures no stale data persists between executions and prevents cross-execution state leakage.

---

## 5. Pause Mechanism

### Access

Only addresses with `EMERGENCY_ADMIN_ROLE` (`_ROLE_6`) can call `pause()` and `unpause()`.

### Scope -- What Pausing Blocks

The following functions check `_checkNotPaused()` and revert with `VM3` when paused:

| Function | Effect When Paused |
|----------|-------------------|
| `deposit(uint256, address)` | Blocked |
| `deposit(uint256, address, address)` | Blocked |
| `mint(uint256, address)` | Blocked |
| `mint(uint256, address, address)` | Blocked |
| `redeem(uint256, address, address)` | Blocked |
| `withdraw(uint256, address, address)` | Blocked |
| `requestDeposit(uint256, address, address)` | Blocked |

### Scope -- What Remains Active During Pause

The following functions are intentionally NOT paused:

| Function | Rationale |
|----------|-----------|
| `requestRedeem` | Allows users to queue redemption requests even during emergencies. Users should always be able to signal their intent to withdraw. |
| `settleTotalAssets` | Allows the manager to update accounting during a pause. This is critical for reflecting losses or position changes that may have triggered the pause in the first place. |

### Design Rationale

The pause mechanism is designed to halt user-facing operations (deposits and claims) while preserving the ability to:
- Accept redemption requests (protecting user withdrawal rights)
- Update accounting (reflecting real-world state changes)
- Execute management operations if needed for recovery

---

## 6. Error Code Reference

All error codes use contract-specific prefixes for debugging. Errors are defined as `string constant` values in `src/errors/Errors.sol`.

### HookExecution Errors (HE)

| Code | Constant | Description |
|------|----------|-------------|
| `HE1` | `HOOKEXECUTION_INVALID_HOOK_ADDRESS` | Hook address is `address(0)` |
| `HE2` | `HOOKEXECUTION_HOOK_ALREADY_INSTALLED` | Hook ID already has an installed address |
| `HE3` | `HOOKEXECUTION_HOOK_NOT_INSTALLED` | Hook ID not found in registry |
| `HE4` | `HOOKEXECUTION_EMPTY_HOOK_CHAIN` | Empty hook execution array passed |

### VaultModule Errors (VM)

| Code | Constant | Description |
|------|----------|-------------|
| `VM1` | `VAULTMODULE_ALREADY_INITIALIZED` | Vault already initialized |
| `VM2` | `VAULTMODULE_INVALID_ASSET_DECIMALS` | Could not retrieve asset decimals |
| `VM3` | `VAULTMODULE_PAUSED` | Operation attempted while vault is paused |
| `VM4` | `VAULTMODULE_MISMATCHED_ARRAYS` | Strategy and value arrays have different lengths |
| `VM5` | `VAULTMODULE_DELTA_EXCEEDS_MAX` | Settlement delta exceeds `maxAllowedDelta` |
| `VM6` | `VAULTMODULE_INVALID_BPS` | BPS value exceeds 10000 |

### ERC4626 Deposit Hook Errors (H4D)

| Code | Constant | Description |
|------|----------|-------------|
| `H4D1` | `HOOK4626DEPOSIT_INVALID_HOOK_DATA` | Invalid deposit data (zero vault, zero receiver, zero assets) |
| `H4D4` | `HOOK4626DEPOSIT_INSUFFICIENT_SHARES` | Shares received below `minShares` threshold |
| `H4D6` | `HOOK4626DEPOSIT_PREVIOUS_HOOK_NOT_FOUND` | Dynamic amount requested but no previous hook in chain |

### ERC4626 Redeem Hook Errors (H4R)

| Code | Constant | Description |
|------|----------|-------------|
| `H4R1` | `HOOK4626REDEEM_INVALID_HOOK_DATA` | Invalid redeem data (zero vault, zero receiver, zero owner, zero shares) |
| `H4R4` | `HOOK4626REDEEM_INSUFFICIENT_ASSETS` | Assets received below `minAssets` threshold |
| `H4R6` | `HOOK4626REDEEM_PREVIOUS_HOOK_NO_OUTPUT` | Dynamic amount requested but no previous hook in chain |

### OneInch Swap Hook Errors (H1I)

| Code | Constant | Description |
|------|----------|-------------|
| `H1I1` | `HOOKONEINCH_INVALID_HOOK_DATA` | Invalid swap data (zero tokens, zero receiver, empty calldata, swap failure) |
| `H1I2` | `HOOKONEINCH_PREVIOUS_HOOK_NOT_FOUND` | Dynamic amount requested but no previous hook in chain |
| `H1I3` | `HOOKONEINCH_INSUFFICIENT_OUTPUT` | Output amount below `minAmountOut` threshold |
| `H1I4` | `HOOKONEINCH_INVALID_ROUTER` | Router address is `address(0)` |
| `H1I5` | `HOOKONEINCH_ROUTER_NOT_ALLOWED` | Router address not in the allowed whitelist |

---

## 7. Known Trust Assumptions

### Manager Trust

The manager (`MANAGER_ROLE`) can manipulate the share price through `settleTotalAssets`. This is inherent to the virtual accounting design -- someone must update `virtualTotalAssets` to reflect yield, losses, and position changes.

**Mitigations:**
- `maxAllowedDelta` limits the magnitude of any single settlement change
- Merkle root provides an auditable breakdown of external holdings
- Off-chain monitoring can detect anomalous settlements
- The admin can revoke `MANAGER_ROLE` at any time

### Registry Admin Trust

The registry administrator controls which `(target, selector, params)` tuples are authorized for execution. A compromised registry admin could:

- Allow calls to malicious contracts
- Block legitimate strategy operations
- Modify parameter restrictions

**Mitigations:**
- Registry is an external contract with its own governance
- Changes to the registry can be monitored on-chain
- The MetaWallet admin can update the registry address if compromised

### Hook Owner Trust

The hook owner (which is the MetaWallet contract itself) has full control over hook operations. Since MetaWallet is the owner:

- Only MetaWallet can call `buildExecutions`, `initializeHookContext`, and `finalizeHookContext`
- Only MetaWallet can manage the router whitelist on `OneInchSwapHook`
- Hook state cannot be manipulated by external parties

However, anyone with `EXECUTOR_ROLE` can trigger hook execution through `executeWithHookExecution`, subject to registry authorization.

### Admin Trust

The `ADMIN_ROLE` holder has broad control:

- Can install arbitrary hook contracts
- Can add arbitrary modules via `MultiFacetProxy`
- Can initialize and configure the vault
- Can grant and revoke all roles (via `OwnableRoles`)

This role should be held by a multisig or governance contract in production.

### Executor / Whitelisted Overlap

Since `EXECUTOR_ROLE` and `WHITELISTED_ROLE` share `_ROLE_1`, granting deposit access to an address also grants execution access. Ensure that addresses granted `_ROLE_1` are trusted with both capabilities.
