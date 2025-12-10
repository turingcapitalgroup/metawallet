# MetaWallet

A hybrid smart contract combining the benefits of an ERC-7540 async vault with the flexibility of a smart wallet for fund management.

## Overview

MetaWallet enables institutional fund managers to operate a vault that accepts user deposits while maintaining full flexibility to deploy capital across DeFi strategies. It features:

- **ERC-7540 Vault**: Async deposit/redeem flow with share-based accounting
- **Smart Wallet**: Arbitrary execution capabilities for strategy management
- **Virtual Accounting**: `totalAssets` remains stable during invest/divest operations
- **Hook System**: Modular, chainable hooks for strategy interactions
- **Merkle Proof Settlements**: Off-chain attestation of external holdings

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         MetaWallet                              │
├─────────────────────────────────────────────────────────────────┤
│  MinimalSmartAccount    │  HookExecution   │  MultiFacetProxy   │
│  (execution + roles)    │  (hook system)   │  (modules)         │
└─────────────────────────────────────────────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
              VaultModule                   Hooks
         (ERC7540 + accounting)     (ERC4626Deposit, Redeem)
```

### Core Components

| Component | Description |
|-----------|-------------|
| `MetaWallet.sol` | Main contract inheriting wallet + vault + hook capabilities |
| `VaultModule.sol` | ERC-7540 vault logic with virtual totalAssets tracking |
| `HookExecution.sol` | Multi-hook execution system for strategy operations |
| `ERC4626ApproveAndDepositHook.sol` | Hook for investing into ERC-4626 vaults |
| `ERC4626RedeemHook.sol` | Hook for divesting from ERC-4626 vaults |

## Accounting Model

MetaWallet uses a minimalistic virtual accounting model:

```
totalAssets = virtualTotalAssets (stored value)
totalIdle   = asset.balanceOf(vault) - pendingDeposits
```

### Key Properties

1. **Deposits** (`deposit`/`mint`): Increase `virtualTotalAssets`
2. **Redemptions** (`redeem`/`withdraw`): Decrease `virtualTotalAssets`
3. **Invest/Divest**: `totalAssets` remains unchanged
4. **Settlements**: Manager updates `virtualTotalAssets` via `settleTotalAssets()`

This design ensures share price stability during strategy operations, which is critical for cross-chain deployments where assets may be "in flight".

## Roles

| Role | Permissions |
|------|-------------|
| `ADMIN_ROLE` | Install/uninstall hooks, add modules, initialize vault |
| `EXECUTOR_ROLE` | Execute wallet operations via hooks |
| `MANAGER_ROLE` | Settle total assets and merkle roots |
| `EMERGENCY_ADMIN_ROLE` | Pause/unpause the vault |

## User Flow

### Depositing

```solidity
// 1. Request deposit (transfers USDC to vault)
vault.requestDeposit(1000e6, user, user);

// 2. Claim shares (instantly fulfilled)
vault.deposit(1000e6, user);
```

### Redeeming

```solidity
// 1. Request redemption (transfers shares to vault)
vault.requestRedeem(shares, user, user);

// 2. Claim assets (limited by totalIdle)
vault.redeem(shares, user, user);
```

Redemptions are limited by `totalIdle` - users can only withdraw up to the actual USDC balance in the vault.

## Manager Operations

### Investing in Strategies

```solidity
ERC4626ApproveAndDepositHook.ApproveAndDepositData memory data =
    ERC4626ApproveAndDepositHook.ApproveAndDepositData({
        vault: EXTERNAL_VAULT,
        assets: 5000e6,
        receiver: address(metaWallet),
        minShares: 0
    });

IHookExecution.HookExecution[] memory hooks = new IHookExecution.HookExecution[](1);
hooks[0] = IHookExecution.HookExecution({
    hookId: keccak256("hook.erc4626.deposit"),
    data: abi.encode(data)
});

metaWallet.executeWithHookExecution(hooks);
```

### Settling After Yield

```solidity
// Update totalAssets to reflect gains/losses
address[] memory strategies = new address[](2);
uint256[] memory values = new uint256[](2);
strategies[0] = VAULT_A;
strategies[1] = VAULT_B;
values[0] = 5000e6;
values[1] = 3000e6;

uint256 newTotalAssets = totalIdle + values[0] + values[1];
bytes32 merkleRoot = metaWallet.computeMerkleRoot(strategies, values);

metaWallet.settleTotalAssets(newTotalAssets, merkleRoot);
```

### Pausing

```solidity
// Emergency pause (blocks all user operations)
metaWallet.pause();

// Resume operations
metaWallet.unpause();
```

## Merkle Validation

External holdings can be validated against the stored merkle root:

```solidity
address[] memory strategies = new address[](2);
uint256[] memory values = new uint256[](2);
strategies[0] = VAULT_A;
strategies[1] = VAULT_B;
values[0] = 5000e6;
values[1] = 3000e6;

bool valid = metaWallet.validateTotalAssets(strategies, values, merkleRoot);
```

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

## Deployment

MetaWallet uses CREATE2 for deterministic addresses across multiple chains. The deployment process involves:

1. Deploy implementation contracts (once per chain)
2. Deploy proxy via factory (same address on all chains)

### Prerequisites

Create a `.env` file:

```bash
# Required
PRIVATE_KEY=0x...
FACTORY_ADDRESS=0x...      # MinimalSmartAccountFactory (same on all chains)
REGISTRY_ADDRESS=0x...     # Your registry contract
ASSET_ADDRESS=0x...        # Underlying asset (e.g., USDC)

# Optional
DEPLOY_SALT=0              # Custom salt for deterministic address
OWNER_ADDRESS=0x...        # Defaults to deployer
VAULT_NAME="Meta USDC"
VAULT_SYMBOL="mUSDC"

# RPC URLs
MAINNET_RPC_URL=https://...
ARBITRUM_RPC_URL=https://...
OPTIMISM_RPC_URL=https://...
BASE_RPC_URL=https://...
POLYGON_RPC_URL=https://...
SEPOLIA_RPC_URL=https://...

# Block Explorer API Keys (for verification)
ETHERSCAN_API_KEY=...
ARBISCAN_API_KEY=...
```

### Quick Start (One Command)

Deploy everything in a single transaction:

```shell
# Deploy to testnet first
make deploy-all-sepolia

# Deploy to mainnet
make deploy-all-mainnet
```

This deploys:
1. MetaWallet implementation
2. VaultModule implementation
3. Proxy via CREATE2 factory
4. ERC4626 deposit/redeem hooks

The proxy address is deterministic - use the same `DEPLOY_SALT` and deployer on all chains to get the same address.

### Step-by-Step Deployment

If you prefer more control, deploy in steps:

#### Step 1: Deploy Implementation

Deploy the MetaWallet implementation and VaultModule to each chain:

```shell
# Deploy to Sepolia (testnet)
make deploy-impl-sepolia

# Deploy to mainnet
make deploy-impl-mainnet

# Deploy to all mainnets
make deploy-impl-all
```

Save the deployed addresses:
- `IMPLEMENTATION_ADDRESS` - MetaWallet implementation
- `VAULT_MODULE_ADDRESS` - VaultModule implementation

#### Step 2: Deploy Proxy

The proxy deployment requires additional environment variables:

```bash
# Add to .env
FACTORY_ADDRESS=0x...          # MinimalSmartAccountFactory (same on all chains)
IMPLEMENTATION_ADDRESS=0x...   # From step 1
VAULT_MODULE_ADDRESS=0x...     # From step 1
REGISTRY_ADDRESS=0x...         # Your registry contract
ASSET_ADDRESS=0x...            # Underlying asset (e.g., USDC)

# Optional
DEPLOY_SALT=0                  # Custom salt for deterministic address
OWNER_ADDRESS=0x...            # Defaults to deployer
VAULT_NAME="Meta USDC"
VAULT_SYMBOL="mUSDC"
```

Predict the proxy address before deploying:

```shell
make predict-address
```

Deploy the proxy (same address on all chains with same salt):

```shell
# Deploy proxy only
make deploy-proxy-sepolia

# Deploy proxy with ERC4626 hooks
make deploy-full-sepolia

# Deploy to all mainnets
make deploy-proxy-all
```

#### Step 3: Deploy Hooks (Optional)

If you deployed without hooks, you can add them later:

```bash
# Add to .env
METAWALLET_ADDRESS=0x...  # Deployed proxy address
```

```shell
# Deploy hooks
make deploy-hooks-mainnet

# Install hooks (requires DEPOSIT_HOOK_ADDRESS, REDEEM_HOOK_ADDRESS)
make install-hooks-mainnet
```

### Multi-Chain Deployment

To deploy to the same address on multiple chains:

1. Use the same `DEPLOY_SALT` on all chains
2. Use the same deployer address (`PRIVATE_KEY`)
3. Ensure the factory is deployed at the same address on all chains

```shell
# Predict address first
FACTORY_ADDRESS=0x... DEPLOYER_ADDRESS=0x... DEPLOY_SALT=0 make predict-address

# Deploy to each chain (will have same address)
make deploy-proxy-mainnet
make deploy-proxy-arbitrum
make deploy-proxy-optimism
make deploy-proxy-base
make deploy-proxy-polygon
```

### Deployment Scripts

| Script | Command | Description |
|--------|---------|-------------|
| `DeployAll` | `deploy-all-*` | **One command**: impl + proxy + hooks |
| `Deploy` | `deploy-impl-*` | Deploy implementation + VaultModule |
| `DeployProxy` | `deploy-proxy-*` | Deploy proxy with VaultModule |
| `DeployProxyWithHooks` | `deploy-full-*` | Deploy proxy + VaultModule + hooks |
| `PredictProxyAddress` | `predict-address` | Predict CREATE2 address |
| `DeployHooks` | `deploy-hooks-*` | Deploy hooks for existing wallet |
| `InstallHooks` | `install-hooks-*` | Install hooks on existing wallet |

### Dry Run

Test deployment without broadcasting:

```shell
make dry-run-impl   # Test implementation deployment
make dry-run-proxy  # Test proxy deployment
```

## Dependencies

- [solady](https://github.com/Vectorized/solady) - Gas-optimized libraries
- [minimal-smart-account](https://github.com/turingcapitalgroup/minimal-smart-account) - Smart wallet base
- [kam](https://github.com/turingcapitalgroup/kam) - Multi-facet proxy and modules

## License

MIT
