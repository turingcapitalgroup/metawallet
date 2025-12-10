# MetaWallet - Makefile
# Multi-chain deployment automation

-include .env

.PHONY: all build test clean deploy-all help

# Default target
all: build test

# =============================================================================
# BUILD & TEST
# =============================================================================

## Build the project
build:
	forge build

## Run tests
test:
	forge test -vvv

## Run tests with gas reporting
test-gas:
	forge test -vvv --gas-report

## Run coverage
coverage:
	forge coverage

## Format code
fmt:
	forge fmt

## Check formatting
fmt-check:
	forge fmt --check

## Clean build artifacts
clean:
	forge clean

## Install dependencies
install:
	forge soldeer install

## Show contract sizes
sizes:
	forge build --sizes

## Generate gas snapshot
snapshot:
	forge snapshot

# =============================================================================
# DEPLOYMENT - IMPLEMENTATION (Deploy once, use on all chains)
# =============================================================================

## Deploy implementation to Sepolia
deploy-impl-sepolia:
	@echo "Deploying implementation to Sepolia..."
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url sepolia \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy implementation to Mainnet
deploy-impl-mainnet:
	@echo "Deploying implementation to Mainnet..."
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url mainnet \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy implementation to Arbitrum
deploy-impl-arbitrum:
	@echo "Deploying implementation to Arbitrum..."
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url arbitrum \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy implementation to Optimism
deploy-impl-optimism:
	@echo "Deploying implementation to Optimism..."
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url optimism \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy implementation to Base
deploy-impl-base:
	@echo "Deploying implementation to Base..."
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url base \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy implementation to Polygon
deploy-impl-polygon:
	@echo "Deploying implementation to Polygon..."
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url polygon \
		--broadcast \
		--verify \
		--slow \
		-vvvv

# =============================================================================
# DEPLOYMENT - PROXY (Same address on all chains with CREATE2)
# =============================================================================

## Deploy proxy to Sepolia
deploy-proxy-sepolia:
	@echo "Deploying proxy to Sepolia..."
	forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url sepolia \
		--broadcast \
		--slow \
		-vvvv

## Deploy proxy to Mainnet
deploy-proxy-mainnet:
	@echo "Deploying proxy to Mainnet..."
	forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url mainnet \
		--broadcast \
		--slow \
		-vvvv

## Deploy proxy to Arbitrum
deploy-proxy-arbitrum:
	@echo "Deploying proxy to Arbitrum..."
	forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url arbitrum \
		--broadcast \
		--slow \
		-vvvv

## Deploy proxy to Optimism
deploy-proxy-optimism:
	@echo "Deploying proxy to Optimism..."
	forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url optimism \
		--broadcast \
		--slow \
		-vvvv

## Deploy proxy to Base
deploy-proxy-base:
	@echo "Deploying proxy to Base..."
	forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url base \
		--broadcast \
		--slow \
		-vvvv

## Deploy proxy to Polygon
deploy-proxy-polygon:
	@echo "Deploying proxy to Polygon..."
	forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url polygon \
		--broadcast \
		--slow \
		-vvvv

# =============================================================================
# DEPLOYMENT - PROXY WITH HOOKS
# =============================================================================

## Deploy proxy with hooks to Sepolia
deploy-full-sepolia:
	@echo "Deploying proxy with hooks to Sepolia..."
	forge script script/Deploy.s.sol:DeployProxyWithHooks \
		--rpc-url sepolia \
		--broadcast \
		--slow \
		-vvvv

## Deploy proxy with hooks to Mainnet
deploy-full-mainnet:
	@echo "Deploying proxy with hooks to Mainnet..."
	forge script script/Deploy.s.sol:DeployProxyWithHooks \
		--rpc-url mainnet \
		--broadcast \
		--slow \
		-vvvv

## Deploy proxy with hooks to Arbitrum
deploy-full-arbitrum:
	@echo "Deploying proxy with hooks to Arbitrum..."
	forge script script/Deploy.s.sol:DeployProxyWithHooks \
		--rpc-url arbitrum \
		--broadcast \
		--slow \
		-vvvv

# =============================================================================
# ONE-COMMAND DEPLOYMENT (Implementation + Proxy + Hooks)
# =============================================================================

## Deploy everything to Sepolia (implementation + proxy + hooks)
deploy-all-sepolia:
	@echo "Deploying everything to Sepolia..."
	forge script script/Deploy.s.sol:DeployAll \
		--rpc-url sepolia \
		--broadcast \
		--slow \
		-vvvv

## Deploy everything to Mainnet
deploy-all-mainnet:
	@echo "Deploying everything to Mainnet..."
	forge script script/Deploy.s.sol:DeployAll \
		--rpc-url mainnet \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy everything to Arbitrum
deploy-all-arbitrum:
	@echo "Deploying everything to Arbitrum..."
	forge script script/Deploy.s.sol:DeployAll \
		--rpc-url arbitrum \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy everything to Optimism
deploy-all-optimism:
	@echo "Deploying everything to Optimism..."
	forge script script/Deploy.s.sol:DeployAll \
		--rpc-url optimism \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy everything to Base
deploy-all-base:
	@echo "Deploying everything to Base..."
	forge script script/Deploy.s.sol:DeployAll \
		--rpc-url base \
		--broadcast \
		--verify \
		--slow \
		-vvvv

## Deploy everything to Polygon
deploy-all-polygon:
	@echo "Deploying everything to Polygon..."
	forge script script/Deploy.s.sol:DeployAll \
		--rpc-url polygon \
		--broadcast \
		--verify \
		--slow \
		-vvvv

# =============================================================================
# HOOKS DEPLOYMENT
# =============================================================================

## Deploy hooks for existing MetaWallet on Sepolia
deploy-hooks-sepolia:
	@echo "Deploying hooks to Sepolia..."
	forge script script/Deploy.s.sol:DeployHooks \
		--rpc-url sepolia \
		--broadcast \
		--slow \
		-vvvv

## Deploy hooks for existing MetaWallet on Mainnet
deploy-hooks-mainnet:
	@echo "Deploying hooks to Mainnet..."
	forge script script/Deploy.s.sol:DeployHooks \
		--rpc-url mainnet \
		--broadcast \
		--slow \
		-vvvv

## Install hooks on existing MetaWallet on Sepolia
install-hooks-sepolia:
	@echo "Installing hooks on Sepolia..."
	forge script script/Deploy.s.sol:InstallHooks \
		--rpc-url sepolia \
		--broadcast \
		--slow \
		-vvvv

## Install hooks on existing MetaWallet on Mainnet
install-hooks-mainnet:
	@echo "Installing hooks on Mainnet..."
	forge script script/Deploy.s.sol:InstallHooks \
		--rpc-url mainnet \
		--broadcast \
		--slow \
		-vvvv

# =============================================================================
# UTILITIES
# =============================================================================

## Predict proxy address (requires FACTORY_ADDRESS, DEPLOYER_ADDRESS)
predict-address:
	@forge script script/Deploy.s.sol:PredictProxyAddress -vvvv

## Dry run implementation deployment
dry-run-impl:
	@echo "Dry run implementation deployment..."
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url sepolia \
		-vvvv

## Dry run proxy deployment
dry-run-proxy:
	@echo "Dry run proxy deployment..."
	forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url sepolia \
		-vvvv

# =============================================================================
# MULTI-CHAIN DEPLOYMENT
# =============================================================================

## Deploy implementation to all mainnets
deploy-impl-all: deploy-impl-mainnet deploy-impl-arbitrum deploy-impl-optimism deploy-impl-base deploy-impl-polygon
	@echo "Implementation deployed to all mainnets!"

## Deploy proxy to all mainnets (same address via CREATE2)
deploy-proxy-all: deploy-proxy-mainnet deploy-proxy-arbitrum deploy-proxy-optimism deploy-proxy-base deploy-proxy-polygon
	@echo "Proxy deployed to all mainnets!"

# =============================================================================
# HELP
# =============================================================================

## Show this help
help:
	@echo "MetaWallet - Makefile Commands"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Build & Test:"
	@echo "  build              Build the project"
	@echo "  test               Run tests"
	@echo "  test-gas           Run tests with gas reporting"
	@echo "  coverage           Run coverage"
	@echo "  fmt                Format code"
	@echo "  fmt-check          Check formatting"
	@echo "  clean              Clean build artifacts"
	@echo "  install            Install dependencies"
	@echo "  sizes              Show contract sizes"
	@echo ""
	@echo "One-Command Deployment (RECOMMENDED):"
	@echo "  deploy-all-sepolia     Deploy everything to Sepolia"
	@echo "  deploy-all-mainnet     Deploy everything to Mainnet"
	@echo "  deploy-all-arbitrum    Deploy everything to Arbitrum"
	@echo "  deploy-all-optimism    Deploy everything to Optimism"
	@echo "  deploy-all-base        Deploy everything to Base"
	@echo "  deploy-all-polygon     Deploy everything to Polygon"
	@echo ""
	@echo "Step-by-Step Deployment:"
	@echo "  deploy-impl-*          Deploy implementation + VaultModule"
	@echo "  deploy-proxy-*         Deploy proxy with VaultModule"
	@echo "  deploy-full-*          Deploy proxy + VaultModule + hooks"
	@echo ""
	@echo "Hooks (for existing wallets):"
	@echo "  deploy-hooks-*         Deploy hooks for existing MetaWallet"
	@echo "  install-hooks-*        Install hooks on existing MetaWallet"
	@echo ""
	@echo "Utilities:"
	@echo "  predict-address        Predict proxy address"
	@echo "  dry-run-impl           Dry run implementation deployment"
	@echo "  dry-run-proxy          Dry run proxy deployment"
	@echo ""
	@echo "Environment Variables:"
	@echo "  PRIVATE_KEY            Deployer private key"
	@echo "  FACTORY_ADDRESS        MinimalSmartAccountFactory address"
	@echo "  REGISTRY_ADDRESS       Registry contract address"
	@echo "  ASSET_ADDRESS          Underlying asset (e.g., USDC)"
	@echo "  DEPLOY_SALT            (optional) Custom salt for CREATE2"
	@echo "  VAULT_NAME             (optional) Vault token name"
	@echo "  VAULT_SYMBOL           (optional) Vault token symbol"
