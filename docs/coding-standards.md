# MetaWallet Coding Standards

This document defines the coding standards for the MetaWallet project. All contributors must follow these conventions to maintain consistency, readability, and audit-readiness across the codebase.

---

## 1. Solidity Version

- **Pragma**: Use `^0.8.20` for all source contracts. Test files may use `^0.8.19` if required by dependencies.
- **License**: Use `SPDX-License-Identifier: MIT` for all source files. Test files may use `UNLICENSED`.
- **Compiler**: The project compiles with `solc 0.8.30` as configured in `foundry.toml`. The `^0.8.20` pragma ensures forward compatibility.
- **EVM target**: `cancun` (transient storage opcodes available).

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
```

---

## 2. Import Conventions

### Named Imports Only

Always use named (selective) imports. Never use wildcard imports (`import "..."` or `import * from "..."`).

```solidity
// Correct
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { OwnableRoles } from "solady/auth/OwnableRoles.sol";

// Incorrect
import "solady/utils/SafeTransferLib.sol";
```

### Import Grouping

Organize imports in the following order, separated by blank lines and preceded by a comment header:

1. **External Libraries** -- third-party dependencies (Solady, MinimalSmartAccount, KAM)
2. **Local Interfaces** -- project interfaces from `src/interfaces/`
3. **Local Contracts** -- project contracts from `src/`
4. **Local Errors** -- error constants from `src/errors/Errors.sol`

```solidity
// External Libraries
import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Local Interfaces
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IHook } from "metawallet/src/interfaces/IHook.sol";

// Local Errors
import {
    HOOK4626DEPOSIT_INSUFFICIENT_SHARES,
    HOOK4626DEPOSIT_INVALID_HOOK_DATA
} from "metawallet/src/errors/Errors.sol";
```

### Remappings

The project uses the following remappings defined in `remappings.txt`:

| Remapping | Target |
|-----------|--------|
| `solady/` | `dependencies/solady-0.1.26/src/` |
| `minimal-smart-account/` | `dependencies/minimal-smart-account-1.0/src/` |
| `kam/` | `dependencies/kam-1.0/src/` |
| `metawallet/src/` | `src/` |
| `metawallet/test/` | `test/` |
| `forge-std/` | `dependencies/forge-std-1.11.0/src/` |

**Always prefer Solady over OpenZeppelin** for gas efficiency. The project uses Solady for `OwnableRoles`, `SafeTransferLib`, `ERC4626`, `EnumerableSetLib`, `FixedPointMathLib`, `MerkleTreeLib`, and more.

---

## 3. Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Constants | `CONSTANT_CASE` | `ADMIN_ROLE`, `BPS_DENOMINATOR`, `USE_PREVIOUS_HOOK_OUTPUT` |
| Immutables | `CONSTANT_CASE` | `NATIVE_ETH` |
| Public state variables | `camelCase` | `chainFork`, (accessed via getter) |
| Private/internal variables | `_camelCase` | `_executionContext`, `_depositContext`, `_preActionBalance` |
| Function parameters | `_camelCase` | `_hookId`, `_hookAddress`, `_newTotalAssets` |
| Function return values | `_camelCase` | `_results`, `_hookAddress`, `_outputAmount` |
| Local variables | `_camelCase` | `_length`, `_shares`, `_amount` |
| Structs | `PascalCase` | `VaultModuleStorage`, `DepositContext`, `SwapData` |
| Interfaces | `I` + `PascalCase` | `IHook`, `IHookExecution`, `IVaultModule`, `IMetaWallet` |
| Events | Past tense / descriptive | `HookInstalled`, `SettlementExecuted`, `Paused` |
| Errors | `CONTRACTNAME_DESCRIPTION` (string constants) | `HOOKEXECUTION_HOOK_NOT_INSTALLED`, `VAULTMODULE_PAUSED` |
| Custom types | `PascalCase` with underscore separators | `ERC7540_Request`, `ERC7540_FilledRequest` |
| Storage location constants | `UPPER_CASE` + `_STORAGE_LOCATION` suffix | `VAULT_MODULE_STORAGE_LOCATION`, `HOOKS_STORAGE_LOCATION` |

### Functions

| Visibility | Convention | Example |
|------------|-----------|---------|
| Public / external | `camelCase` | `installHook()`, `settleTotalAssets()`, `totalIdle()` |
| Internal / private | `_camelCase` | `_checkAdminRole()`, `_installHook()`, `_getHookExecutionStorage()` |

---

## 4. Error Handling

### Centralized Error Definitions

All error constants are defined in a single file: `src/errors/Errors.sol`. Errors are declared as `string constant` values at the file level (not inside contracts or interfaces).

### Naming Pattern

```
CONTRACTNAME_DESCRIPTIVE_NAME = "PREFIX_NUMBER"
```

### Prefix Mapping

| Contract | Variable Prefix | Code Prefix |
|----------|----------------|-------------|
| HookExecution | `HOOKEXECUTION_` | `HE` |
| VaultModule | `VAULTMODULE_` | `VM` |
| ERC4626ApproveAndDepositHook | `HOOK4626DEPOSIT_` | `H4D` |
| ERC4626RedeemHook | `HOOK4626REDEEM_` | `H4R` |
| OneInchSwapHook | `HOOKONEINCH_` | `H1I` |

### Example

```solidity
// In src/errors/Errors.sol
string constant HOOKEXECUTION_INVALID_HOOK_ADDRESS = "HE1";
string constant HOOKEXECUTION_HOOK_ALREADY_INSTALLED = "HE2";
string constant VAULTMODULE_PAUSED = "VM3";
string constant HOOKONEINCH_ROUTER_NOT_ALLOWED = "H1I5";
```

### Usage

Use `require()` with the imported string constant:

```solidity
import { HOOKEXECUTION_HOOK_NOT_INSTALLED } from "metawallet/src/errors/Errors.sol";

require(_hookAddress != address(0), HOOKEXECUTION_HOOK_NOT_INSTALLED);
```

For ERC-7540 base errors (which are part of the standard), use custom `error` declarations with `revert`:

```solidity
error InvalidController();
error InvalidZeroAssets();

if (assets == 0) revert InvalidZeroAssets();
```

---

## 5. NatSpec Documentation

### When to Use Each Tag

| Tag | Usage |
|-----|-------|
| `@title` | Contract and interface declarations. One per file. |
| `@notice` | All public/external functions, events, errors, structs, and state variables. Describes **what** it does for end users. |
| `@dev` | Implementation details, edge cases, security considerations. Describes **how/why** for developers. |
| `@param` | Every function parameter. Use the parameter name without the underscore prefix in the description. |
| `@return` | Every named return value. |
| `@inheritdoc` | When overriding a function already documented in a parent contract or interface. Place before any additional `@param` or `@dev` tags. |
| `@custom:storage-location` | On storage structs following the ERC-7201 pattern. Format: `erc7201:namespace.storage.ContractName` |

### Examples

**Interface documentation (defines the canonical NatSpec):**

```solidity
/// @title IVaultModule
/// @notice Interface for the vault module facet
interface IVaultModule {
    /// @notice Emitted when a settlement is executed
    event SettlementExecuted(uint256 indexed totalAssets, bytes32 indexed merkleRoot);

    /// @notice Directly settles the total assets and merkle root
    /// @param _newTotalAssets The new total asset amount to be set
    /// @param _merkleRoot The Merkle root of the strategy holdings
    function settleTotalAssets(uint256 _newTotalAssets, bytes32 _merkleRoot) external;
}
```

**Implementation documentation (uses @inheritdoc):**

```solidity
/// @inheritdoc IVaultModule
function settleTotalAssets(uint256 _newTotalAssets, bytes32 _merkleRoot) external {
    _checkManagerRole();
    // ...
}
```

**Storage struct documentation:**

```solidity
/// @notice Storage structure for hooks
/// @custom:storage-location erc7201:metawallet.storage.HookExecution
struct HookExecutionStorage {
    /// @notice Registry of installed hooks by identifier
    mapping(bytes32 => address) hooks;
    /// @notice Array of all installed hook identifiers for enumeration
    EnumerableSetLib.Bytes32Set hookIds;
}
```

---

## 6. Section Dividers

Use KAM-style section dividers to organize contract code into logical blocks. The format uses a comment block with forward slashes.

### Format

```solidity
/* ///////////////////////////////////////////////////////////////
                      SECTION TITLE
///////////////////////////////////////////////////////////////*/
```

### Standard Section Order

1. CONSTANTS
2. STRUCTURES (or STORAGE if the struct is the storage struct)
3. STORAGE
4. STORAGE ACCESS
5. INTERNAL CHECKS
6. CONSTRUCTOR (if applicable)
7. Core logic sections (e.g., HOOK MANAGEMENT, ERC7540 LOGIC, SETTLEMENT LOGIC)
8. AUTHORIZATION
9. VALIDATION HELPERS
10. VIEW FUNCTIONS

### Example

```solidity
contract MyContract {
    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_VALUE = 1000;

    /* ///////////////////////////////////////////////////////////////
                              STORAGE
    ///////////////////////////////////////////////////////////////*/

    uint256 private _value;

    /* ///////////////////////////////////////////////////////////////
                          INTERNAL CHECKS
    ///////////////////////////////////////////////////////////////*/

    function _checkValue(uint256 _v) internal pure {
        require(_v <= MAX_VALUE, "exceeds max");
    }

    /* ///////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function getValue() external view returns (uint256 _val) {
        return _value;
    }
}
```

---

## 7. Storage Patterns

### ERC-7201 Namespaced Storage

All upgradeable contracts use ERC-7201 namespaced storage to prevent storage collisions between modules and proxy implementations.

### Full Example

```solidity
/// @notice Storage structure for the module
/// @custom:storage-location erc7201:metawallet.storage.MyModule
struct MyModuleStorage {
    uint256 someValue;
    mapping(address => uint256) balances;
    bool initialized;
}

// Step 1: Compute the storage slot
// keccak256(abi.encode(uint256(keccak256("metawallet.storage.MyModule")) - 1)) & ~bytes32(uint256(0xff))
bytes32 private constant MY_MODULE_STORAGE_LOCATION =
    0x...; // pre-computed value

// Step 2: Storage accessor function
/// @notice Get the module storage struct
/// @return $ The storage struct reference
function _getMyModuleStorage() internal pure returns (MyModuleStorage storage $) {
    assembly {
        $.slot := MY_MODULE_STORAGE_LOCATION
    }
}

// Step 3: Usage in functions
function doSomething(uint256 _value) external {
    MyModuleStorage storage $ = _getMyModuleStorage();
    $.someValue = _value;
}
```

### Storage Slot Computation

The storage slot follows the ERC-7201 formula:

```
keccak256(abi.encode(uint256(keccak256("namespace.storage.ContractName")) - 1)) & ~bytes32(uint256(0xff))
```

The `& ~bytes32(uint256(0xff))` mask clears the last byte, providing 256 contiguous slots starting at the computed location.

### Namespaces Used in This Project

| Namespace | Contract |
|-----------|----------|
| `metawallet.storage.HookExecution` | HookExecution |
| `metawallet.storage.VaultModule` | VaultModule |
| `metawallet.storage.erc7540` | ERC7540 |
| `minimalaccount.storage` | MinimalSmartAccount |
| `kam.storage.MultiFacetProxy` | MultiFacetProxy |

---

## 8. Formatting

The project uses `forge fmt` with the following configuration from `foundry.toml`:

```toml
[fmt]
bracket_spacing = true
int_types = "long"
line_length = 120
multiline_func_header = "all"
number_underscore = "thousands"
quote_style = "double"
tab_width = 4
sort_imports = true
```

### Key Rules

| Setting | Value | Meaning |
|---------|-------|---------|
| `bracket_spacing` | `true` | Space inside `{ }` for mappings and structs: `mapping(bytes32 => address)` |
| `int_types` | `"long"` | Use `uint256` and `int256`, never `uint` or `int` |
| `line_length` | `120` | Maximum line width before wrapping |
| `multiline_func_header` | `"all"` | Each parameter on its own line when function signature exceeds line length |
| `number_underscore` | `"thousands"` | Use underscores in numeric literals: `10_000`, `1_000_000` |
| `quote_style` | `"double"` | Double quotes for string literals: `"HE1"` |
| `tab_width` | `4` | 4-space indentation |
| `sort_imports` | `true` | Imports are sorted alphabetically within each group |

### Running the Formatter

```shell
forge fmt
```

Run `forge fmt` after every code change. This is enforced by convention.

---

## 9. Security Practices

### Checks-Effects-Interactions (CEI) Pattern

Always perform checks first, then state changes, then external calls.

```solidity
function redeem(uint256 shares, address to, address controller) public virtual override returns (uint256 assets) {
    // CHECKS
    _checkNotPaused();
    _validateController(controller);
    if (shares > maxRedeem(controller)) revert RedeemMoreThanMax();

    // EFFECTS
    assets = convertToAssets(shares);
    _fulfillRedeemRequest(shares, assets, controller, true);
    (assets,) = _withdraw(assets, shares, to, controller);
    _getVaultModuleStorage().virtualTotalAssets -= assets;

    // INTERACTIONS happen inside _withdraw (safeTransfer)
}
```

### Approval Resets

Always reset token approvals to zero after use, especially for router interactions. This prevents residual approvals from being exploited.

```solidity
// Before: approve exact amount
_executions[0] = Execution({
    target: _swapData.srcToken,
    callData: abi.encodeWithSelector(IERC20.approve.selector, _swapData.router, _swapData.amountIn),
    value: 0
});

// After: reset to zero
_executions[3] = Execution({
    target: _swapData.srcToken,
    callData: abi.encodeWithSelector(IERC20.approve.selector, _swapData.router, uint256(0)),
    value: 0
});
```

Use `safeApproveWithRetry` from Solady for tokens that require resetting to zero before setting a new allowance (e.g., USDT):

```solidity
_asset.safeApproveWithRetry(_vault, _amount);
```

### Balance-Delta Tracking

When measuring the output of an external operation (redemptions, swaps), use the snapshot-then-delta pattern instead of relying on return values alone:

```solidity
// Step 1: Snapshot balance before action
function snapshotBalance(address _token, address _account) external onlyOwner {
    _preActionBalance = IERC20(_token).balanceOf(_account);
}

// Step 2: Compute delta after action
function storeRedeemContextStatic(/* ... */) external onlyOwner {
    uint256 _assetsReceived = IERC20(_asset).balanceOf(_receiver) - _preActionBalance;
    // ...
}
```

### Input Validation

Validate all inputs at function entry. Use `require()` with descriptive error constants:

```solidity
require(_hookAddress != address(0), HOOKEXECUTION_INVALID_HOOK_ADDRESS);
require(_depositData.vault != address(0), HOOK4626DEPOSIT_INVALID_HOOK_DATA);
require(_depositData.receiver != address(0), HOOK4626DEPOSIT_INVALID_HOOK_DATA);
```

### Access Control

- Use Solady's `OwnableRoles` for role-based access control.
- Define roles as named constants derived from `_ROLE_N` slots.
- Use internal `_check*Role()` helper functions for readability:

```solidity
uint256 public constant ADMIN_ROLE = _ROLE_0;
uint256 public constant WHITELISTED_ROLE = _ROLE_1;
uint256 public constant MANAGER_ROLE = _ROLE_4;
uint256 public constant EMERGENCY_ADMIN_ROLE = _ROLE_6;

function _checkManagerRole() internal view {
    _checkRoles(MANAGER_ROLE);
}
```

- Hook contracts use Solady's `Ownable` with `onlyOwner` modifier, where the owner is the MetaWallet proxy address.
- Every external call made through `_executeOperations` is validated against the `Registry` contract via `authorizeCall`.

### Router Whitelisting

External protocol integrations (such as the 1inch router) use an allowlist pattern:

```solidity
mapping(address => bool) private _allowedRouters;

require(_allowedRouters[_swapData.router], HOOKONEINCH_ROUTER_NOT_ALLOWED);
```

### Settlement Guardrails

The `maxAllowedDelta` setting prevents the manager from making unbounded changes to `virtualTotalAssets` during settlement:

```solidity
uint256 _deltaBps = (_delta * BPS_DENOMINATOR) / _currentTotalAssets;
require(_deltaBps <= _maxDelta, VAULTMODULE_DELTA_EXCEEDS_MAX);
```

---

## 10. Testing Standards

### Framework

All tests use **Foundry** (`forge test`). Test files are in the `test/` directory.

### File Naming

| Type | Pattern | Example |
|------|---------|---------|
| Unit tests | `ContractName.t.sol` | `ERC7540.t.sol` |
| Fuzz tests | `ContractNameFuzzTest.t.sol` | `VaultModuleFuzzTest.t.sol` |
| Base test fixtures | `base/BaseTest.t.sol` | `test/base/BaseTest.t.sol` |
| Helper contracts | `helpers/Name.sol` | `test/helpers/Tokens.sol` |
| Mock contracts | `helpers/mocks/MockName.sol` | `test/helpers/mocks/MockOneInchRouter.sol` |
| Utility libraries | `utils/Name.sol` | `test/utils/Utilities.sol` |

### Test Function Naming

Use descriptive names that convey the scenario and expected outcome:

```solidity
function test_deposit_updatesVirtualTotalAssets() public { ... }
function test_redeem_revertsWhenPaused() public { ... }
function testFuzz_deposit_correctSharesMinted(uint256 assets) public { ... }
```

### Fuzz Testing

- **One path per fuzzed test**: each fuzz test should cover a single execution path.
- **Use `bound()` instead of `vm.assume()`**: `bound()` constrains inputs without discarding runs.

```solidity
// Correct
function testFuzz_deposit(uint256 assets) public {
    assets = bound(assets, 1, type(uint128).max);
    // ...
}

// Incorrect -- wastes fuzzing runs
function testFuzz_deposit(uint256 assets) public {
    vm.assume(assets > 0 && assets < type(uint128).max);
    // ...
}
```

### Coverage Target

Target **100% branch coverage** across all source contracts in `src/`.

```shell
forge coverage
```

### Build Command

When building for tests, use:

```shell
forge build --use $(which solx)
```

### Test Fixtures

Tests extend `BaseTest` which provides:

- A `Users` struct with pre-funded accounts: `owner`, `admin`, `executor`, `alice`, `bob`, `charlie`
- Fork testing support via `FORK` environment variable
- A `Utilities` helper for creating labeled, funded user addresses

```solidity
contract MyTest is BaseTest {
    function setUp() public {
        _setUp("ETHEREUM", 20_000_000);
        // Additional setup...
    }
}
```
