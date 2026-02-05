# MetaWallet Interface Reference

## Inheritance Overview

```
IERC20
  |
IERC4626
  |
IERC7540
  |
IMetaWallet --- IVaultModule
  |         \
  |          -- IHookExecution
  |
IMinimalSmartAccount (external dependency)

IHook (standalone)
IHookResult (standalone)
```

---

## 1. IMetaWallet

**File:** `src/interfaces/IMetaWallet.sol`

Composite interface for the MetaWallet smart wallet. Aggregates all vault, hook, and smart account functionality into a single interface.

**Inherits:** `IERC7540`, `IVaultModule`, `IMinimalSmartAccount`, `IHookExecution`

This interface declares no additional functions, events, or errors. All members are inherited from its parent interfaces.

---

## 2. IHookExecution

**File:** `src/interfaces/IHookExecution.sol`

Manages installation, removal, and chained execution of hook contracts on the wallet.

**Inherits:** none

### Structs

| Struct | Fields | Description |
|--------|--------|-------------|
| `HookExecution` | `bytes32 hookId`, `bytes data` | Configuration payload for a single hook execution step. |

### Functions

#### State-Changing

| Function | Signature | Description |
|----------|-----------|-------------|
| `installHook` | `installHook(bytes32 hookId, address hookAddress) external` | Registers a hook contract under a unique identifier (e.g., `keccak256("hook.erc4626.deposit")`). |
| `uninstallHook` | `uninstallHook(bytes32 hookId) external` | Removes a previously installed hook by its identifier. |
| `executeWithHookExecution` | `executeWithHookExecution(HookExecution[] calldata hookExecutions) external returns (bytes[] memory)` | Executes an ordered chain of hooks. Each hook builds its own execution logic and hooks can consume output from previous hooks in the chain. Returns the final execution results. |

**Parameters -- `installHook`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `hookId` | `bytes32` | Unique identifier for the hook. |
| `hookAddress` | `address` | Address of the hook contract (must implement `IHook`). |

**Parameters -- `uninstallHook`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `hookId` | `bytes32` | Identifier of the hook to remove. |

**Parameters -- `executeWithHookExecution`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `hookExecutions` | `HookExecution[]` | Ordered array of hook execution configs to run sequentially. |

**Returns:** `bytes[]` -- aggregated return data from all executed hooks.

#### View

| Function | Signature | Description |
|----------|-----------|-------------|
| `getHook` | `getHook(bytes32 hookId) external view returns (address)` | Returns the hook contract address for a given identifier. Returns `address(0)` if not installed. |
| `getInstalledHooks` | `getInstalledHooks() external view returns (bytes32[] memory)` | Returns all currently installed hook identifiers. |

### Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `HookInstalled` | `bytes32 indexed hookId`, `address indexed hook` | Emitted when a hook is registered. |
| `HookUninstalled` | `bytes32 indexed hookId`, `address indexed hook` | Emitted when a hook is removed. |
| `HookExecutionStarted` | `bytes32 indexed hookId`, `address indexed hook` | Emitted when execution of a hook begins. |
| `HookExecutionCompleted` | `bytes32 indexed hookId`, `address indexed hook` | Emitted when execution of a hook finishes. |

---

## 3. IVaultModule

**File:** `src/interfaces/IVaultModule.sol`

Vault administration module for settlement, pausing, and Merkle-root-based strategy accounting.

**Inherits:** none

### Functions

#### State-Changing

| Function | Signature | Description |
|----------|-----------|-------------|
| `initializeVault` | `initializeVault(address _asset, string memory _name, string memory _symbol) external` | Initializes vault logic with the underlying asset address and ERC-20 metadata for the vault token. |
| `settleTotalAssets` | `settleTotalAssets(uint256 _newTotalAssets, bytes32 _merkleRoot) external` | Directly sets the vault's total asset value and the Merkle root of strategy holdings. |
| `setMaxAllowedDelta` | `setMaxAllowedDelta(uint256 _maxAllowedDelta) external` | Sets the maximum allowed delta (in BPS, where 10000 = 100%) for settlement validation. 0 disables the check. |
| `pause` | `pause() external` | Pauses the vault. Restricted to EMERGENCY_ADMIN. |
| `unpause` | `unpause() external` | Unpauses the vault. Restricted to EMERGENCY_ADMIN. |

**Parameters -- `initializeVault`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `_asset` | `address` | Address of the underlying ERC-20 asset. |
| `_name` | `string` | Name of the vault share token. |
| `_symbol` | `string` | Symbol of the vault share token. |

**Parameters -- `settleTotalAssets`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `_newTotalAssets` | `uint256` | New total asset amount to record. |
| `_merkleRoot` | `bytes32` | Merkle root derived from strategy holdings. |

**Parameters -- `setMaxAllowedDelta`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `_maxAllowedDelta` | `uint256` | Maximum delta in basis points. |

#### View

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `sharePrice` | `sharePrice() external view returns (uint256)` | `uint256` | Estimated price of one vault share in asset terms. |
| `totalIdle` | `totalIdle() external view returns (uint256)` | `uint256` | Actual underlying asset balance held directly in the vault (not deployed to strategies). |
| `merkleRoot` | `merkleRoot() external view returns (bytes32)` | `bytes32` | Current Merkle root of strategy-level asset accounting. |
| `paused` | `paused() external view returns (bool)` | `bool` | Whether the vault is currently paused. |
| `maxAllowedDelta` | `maxAllowedDelta() external view returns (uint256)` | `uint256` | Maximum allowed BPS delta for settlements. |

#### Pure

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `computeMerkleRoot` | `computeMerkleRoot(address[] calldata _strategies, uint256[] calldata _values) external pure returns (bytes32)` | `bytes32` | Computes a Merkle root from parallel arrays of strategy addresses and their asset values. |
| `validateTotalAssets` | `validateTotalAssets(address[] calldata _strategies, uint256[] calldata _values, bytes32 _merkleRoot) external pure returns (bool)` | `bool` | Validates that the given strategy holdings produce the expected Merkle root. |

### Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `SettlementExecuted` | `uint256 indexed totalAssets`, `bytes32 indexed merkleRoot` | Emitted after a settlement updates total assets and Merkle root. |
| `Paused` | `address indexed account` | Emitted when the vault is paused. |
| `Unpaused` | `address indexed account` | Emitted when the vault is unpaused. |
| `MaxAllowedDeltaUpdated` | `uint256 indexed maxAllowedDelta` | Emitted when the max allowed delta is changed. |

---

## 4. IHook

**File:** `src/interfaces/IHook.sol`

Interface that individual hook contracts must implement. Hooks build their own execution logic and participate in chained execution flows.

**Inherits:** none

**Uses:** `Execution` struct from `IMinimalSmartAccount` (`{ address target, uint256 value, bytes callData }`)

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `buildExecutions` | `buildExecutions(address previousHook, bytes calldata data) external view returns (Execution[] memory executions)` | Constructs the array of `Execution` structs for this hook, including any pre-hook and post-hook steps. Receives the address of the previous hook in the chain (`address(0)` if first) so it can consume prior outputs. |
| `initializeHookContext` | `initializeHookContext() external` | Sets up execution context before the hook runs. |
| `finalizeHookContext` | `finalizeHookContext() external` | Resets execution state after the hook completes. |

**Parameters -- `buildExecutions`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `previousHook` | `address` | Address of the preceding hook in the chain. `address(0)` if this is the first hook. |
| `data` | `bytes` | Hook-specific configuration data encoded by the caller. |

**Returns:** `Execution[] memory` -- ordered array of low-level calls the wallet should execute.

---

## 5. IHookResult

**File:** `src/interfaces/IHookResult.sol`

Optional interface for hooks that produce output values consumable by subsequent hooks in a chain.

**Inherits:** none

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `getOutputAmount` | `getOutputAmount() external view returns (uint256)` | `uint256` | Returns the output amount from this hook's most recent execution. Used by downstream hooks to read the result of upstream hooks. |

---

## 6. IERC7540

**File:** `src/interfaces/IERC7540.sol`

Asynchronous Tokenized Vault interface (ERC-7540). Adds request-based deposit and redeem flows on top of ERC-4626.

**Inherits:** `IERC4626`

### Functions

#### State-Changing

| Function | Signature | Description |
|----------|-----------|-------------|
| `requestDeposit` | `requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId)` | Submits a request to deposit `assets`. Returns a unique request identifier. |
| `requestRedeem` | `requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId)` | Submits a request to redeem `shares`. Returns a unique request identifier. |

**Parameters -- `requestDeposit`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `assets` | `uint256` | Amount of underlying assets to deposit. |
| `controller` | `address` | Address that will control (claim) this request. |
| `owner` | `address` | Address that owns the assets being deposited. |

**Parameters -- `requestRedeem`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `shares` | `uint256` | Amount of vault shares to redeem. |
| `controller` | `address` | Address that will control (claim) this request. |
| `owner` | `address` | Address that owns the shares being redeemed. |

#### View

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `pendingDepositRequest` | `pendingDepositRequest(address controller) external view returns (uint256)` | `uint256` | Amount of assets pending deposit for a controller. |
| `claimableDepositRequest` | `claimableDepositRequest(address controller) external view returns (uint256)` | `uint256` | Amount of assets claimable (ready to finalize) for a controller. |
| `pendingRedeemRequest` | `pendingRedeemRequest(address controller) external view returns (uint256)` | `uint256` | Amount of shares pending redemption for a controller. |
| `claimableRedeemRequest` | `claimableRedeemRequest(address controller) external view returns (uint256)` | `uint256` | Amount of shares claimable (ready to finalize) for a controller. |
| `maxDeposit` | `maxDeposit(address controller) external view returns (uint256)` | `uint256` | Maximum assets depositable by a controller. |
| `maxMint` | `maxMint(address controller) external view returns (uint256)` | `uint256` | Maximum shares mintable by a controller. |
| `maxRedeem` | `maxRedeem(address controller) external view returns (uint256)` | `uint256` | Maximum shares redeemable by a controller. |
| `maxWithdraw` | `maxWithdraw(address controller) external view returns (uint256)` | `uint256` | Maximum assets withdrawable by a controller. |

### Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `DepositRequest` | `address indexed controller`, `address indexed owner`, `uint256 indexed requestId`, `address sender`, `uint256 assets` | Emitted when a deposit request is submitted. |
| `RedeemRequest` | `address indexed controller`, `address indexed owner`, `uint256 indexed requestId`, `address sender`, `uint256 shares` | Emitted when a redeem request is submitted. |

---

## 7. IERC4626

**File:** `src/interfaces/IERC4626.sol`

Standard Tokenized Vault interface (ERC-4626). Provides synchronous deposit, mint, withdraw, and redeem operations over an underlying ERC-20 asset.

**Inherits:** `IERC20`

### Functions

#### State-Changing

| Function | Signature | Description |
|----------|-----------|-------------|
| `deposit` | `deposit(uint256 assets, address receiver) external returns (uint256 shares)` | Deposits `assets` of the underlying token and mints vault shares to `receiver`. |
| `mint` | `mint(uint256 shares, address receiver) external returns (uint256 assets)` | Mints exactly `shares` vault shares to `receiver`, pulling the required underlying assets. |
| `withdraw` | `withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares)` | Burns shares from `owner` and sends `assets` of the underlying token to `receiver`. |
| `redeem` | `redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets)` | Burns `shares` from `owner` and sends the corresponding underlying assets to `receiver`. |

#### View

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `asset` | `asset() external view returns (address)` | `address` | Address of the underlying ERC-20 asset. |
| `totalAssets` | `totalAssets() external view returns (uint256)` | `uint256` | Total amount of underlying assets managed by the vault. |
| `convertToShares` | `convertToShares(uint256 assets) external view returns (uint256)` | `uint256` | Converts an asset amount to the equivalent share amount. |
| `convertToAssets` | `convertToAssets(uint256 shares) external view returns (uint256)` | `uint256` | Converts a share amount to the equivalent asset amount. |
| `maxDeposit` | `maxDeposit(address receiver) external view returns (uint256)` | `uint256` | Maximum assets depositable for `receiver`. |
| `previewDeposit` | `previewDeposit(uint256 assets) external view returns (uint256)` | `uint256` | Simulates the shares received for a given deposit amount. |
| `maxMint` | `maxMint(address receiver) external view returns (uint256)` | `uint256` | Maximum shares mintable for `receiver`. |
| `previewMint` | `previewMint(uint256 shares) external view returns (uint256)` | `uint256` | Simulates the assets required to mint a given number of shares. |
| `maxWithdraw` | `maxWithdraw(address owner) external view returns (uint256)` | `uint256` | Maximum assets withdrawable by `owner`. |
| `previewWithdraw` | `previewWithdraw(uint256 assets) external view returns (uint256)` | `uint256` | Simulates the shares burned for a given withdrawal amount. |
| `maxRedeem` | `maxRedeem(address owner) external view returns (uint256)` | `uint256` | Maximum shares redeemable by `owner`. |
| `previewRedeem` | `previewRedeem(uint256 shares) external view returns (uint256)` | `uint256` | Simulates the assets received for redeeming a given number of shares. |

### Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `Deposit` | `address indexed sender`, `address indexed owner`, `uint256 assets`, `uint256 shares` | Emitted when assets are deposited and shares are minted. |
| `Withdraw` | `address indexed sender`, `address indexed receiver`, `address indexed owner`, `uint256 assets`, `uint256 shares` | Emitted when shares are burned and assets are withdrawn. |

---

## 8. IERC20

**File:** `src/interfaces/IERC20.sol`

Minimal ERC-20 token interface. Base token standard used by all vault interfaces in the hierarchy.

**Inherits:** none

### Functions

#### State-Changing

| Function | Signature | Description |
|----------|-----------|-------------|
| `transfer` | `transfer(address to, uint256 amount) external returns (bool)` | Transfers `amount` tokens to `to`. |
| `approve` | `approve(address spender, uint256 amount) external returns (bool)` | Approves `spender` to spend up to `amount` tokens on behalf of the caller. |
| `transferFrom` | `transferFrom(address from, address to, uint256 amount) external returns (bool)` | Transfers `amount` tokens from `from` to `to`, consuming allowance. |

#### View

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `totalSupply` | `totalSupply() external view returns (uint256)` | `uint256` | Total token supply in existence. |
| `balanceOf` | `balanceOf(address account) external view returns (uint256)` | `uint256` | Token balance of `account`. |
| `allowance` | `allowance(address owner, address spender) external view returns (uint256)` | `uint256` | Remaining number of tokens `spender` is approved to spend on behalf of `owner`. |

### Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `Transfer` | `address indexed from`, `address indexed to`, `uint256 value` | Emitted on every token transfer (including mints where `from` is `address(0)` and burns where `to` is `address(0)`). |
| `Approval` | `address indexed owner`, `address indexed spender`, `uint256 value` | Emitted when an allowance is set or changed via `approve`. |

---

## Appendix: IMinimalSmartAccount (External Dependency)

**Source:** `minimal-smart-account` package

Smart account execution interface inherited by `IMetaWallet`. Provides the core transaction execution primitive.

### Structs

| Struct | Fields | Description |
|--------|--------|-------------|
| `Execution` | `address target`, `uint256 value`, `bytes callData` | A single low-level call to execute. Used throughout the hook system. |

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `execute` | `execute(ModeCode mode, bytes calldata executionCalldata) external returns (bytes[] memory)` | Executes one or more transactions. `ModeCode` encodes the call type and execution mode (DEFAULT = revert on failure, TRY = continue on failure). |
| `accountId` | `accountId() external view returns (string memory)` | Returns the account implementation identifier in `vendorname.accountname.semver` format. |
| `nonce` | `nonce() external view returns (uint256)` | Returns the nonce of the last executed transaction. |

### Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `Executed` | `uint256 indexed nonce`, `address executor`, `address indexed target`, `bytes indexed callData`, `uint256 value`, `bytes result` | Emitted on successful transaction execution. |
| `TryExecutionFailed` | `uint256 numberInBatch` | Emitted when a transaction fails in TRY mode (non-reverting batch). |

### Errors

| Error | Parameters | Description |
|-------|------------|-------------|
| `UnsupportedCallType` | `CallType callType` | Thrown when an unsupported call type is requested. |
| `UnsupportedExecType` | `ExecType execType` | Thrown when an unsupported execution type is requested. |
