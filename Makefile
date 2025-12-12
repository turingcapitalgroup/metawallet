# MetaWallet Deployment Makefile
# Usage: make deploy-mainnet, make deploy-sepolia, make deploy-localhost
-include .env
export

.PHONY: help deploy-mainnet deploy-sepolia deploy-localhost deploy-all verify clean clean-all format-output

# Default target
help:
	@echo "MetaWallet Deployment Commands"
	@echo "=============================="
	@echo ""
	@echo "Deployment (full protocol):"
	@echo "  make deploy-localhost   - Deploy to localhost (anvil)"
	@echo "  make deploy-sepolia     - Deploy to Sepolia testnet"
	@echo "  make deploy-mainnet     - Deploy to mainnet"
	@echo ""
	@echo "Individual steps:"
	@echo "  make deploy-impl-*      - Deploy implementation + VaultModule only"
	@echo "  make deploy-proxy-*     - Deploy proxy (requires impl deployed)"
	@echo "  make deploy-hooks-*     - Deploy hooks (requires proxy deployed)"
	@echo "  make install-hooks-*    - Install hooks on existing MetaWallet"
	@echo ""
	@echo "Utilities:"
	@echo "  make verify             - Verify deployment files exist"
	@echo "  make clean              - Clean localhost deployment files"
	@echo "  make clean-all          - Clean ALL deployment files (DANGER)"
	@echo "  make format-output      - Format JSON output files"
	@echo "  make predict-address    - Predict proxy address"
	@echo ""
	@echo "Build & Test:"
	@echo "  make build              - Build the project"
	@echo "  make test               - Run tests"
	@echo "  make coverage           - Run coverage"
	@echo "  make fmt                - Format code"
	@echo ""
	@echo "Security:"
	@echo "  - Localhost: Uses anvil default private key (no secrets)"
	@echo "  - Production: Uses keystore (--account keyDeployer)"
	@echo "  - NEVER store private keys in .env or config files"

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORK-SPECIFIC DEPLOYMENTS
# ═══════════════════════════════════════════════════════════════════════════════

# Localhost deployment (uses anvil default private key - no secrets needed)
deploy-localhost:
	@echo "Deploying to LOCALHOST..."
	@forge script script/Deploy.s.sol:DeployAll \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow
	@$(MAKE) format-output

# Sepolia deployment (uses keystore for production security)
deploy-sepolia:
	@echo "Deploying to SEPOLIA..."
	@forge script script/Deploy.s.sol:DeployAll \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow \
		--verify \
		--etherscan-api-key $${ETHERSCAN_API_KEY}
	@$(MAKE) format-output

# Mainnet deployment (uses keystore for production security)
deploy-mainnet:
	@echo "Deploying to MAINNET..."
	@forge script script/Deploy.s.sol:DeployAll \
		--rpc-url $${RPC_MAINNET} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow \
		--verify \
		--etherscan-api-key $${ETHERSCAN_API_KEY}
	@$(MAKE) format-output

# ═══════════════════════════════════════════════════════════════════════════════
# STEP-BY-STEP DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════

# Implementation only
deploy-impl-localhost:
	@echo "Deploying implementation to LOCALHOST..."
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

deploy-impl-sepolia:
	@echo "Deploying implementation to SEPOLIA..."
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

deploy-impl-mainnet:
	@echo "Deploying implementation to MAINNET..."
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url $${RPC_MAINNET} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# Proxy only (requires implementation deployed)
deploy-proxy-localhost:
	@echo "Deploying proxy to LOCALHOST..."
	@forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

deploy-proxy-sepolia:
	@echo "Deploying proxy to SEPOLIA..."
	@forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

deploy-proxy-mainnet:
	@echo "Deploying proxy to MAINNET..."
	@forge script script/Deploy.s.sol:DeployProxy \
		--rpc-url $${RPC_MAINNET} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# Hooks only (requires proxy deployed)
deploy-hooks-localhost:
	@echo "Deploying hooks to LOCALHOST..."
	@forge script script/Deploy.s.sol:DeployHooks \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

deploy-hooks-sepolia:
	@echo "Deploying hooks to SEPOLIA..."
	@forge script script/Deploy.s.sol:DeployHooks \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

deploy-hooks-mainnet:
	@echo "Deploying hooks to MAINNET..."
	@forge script script/Deploy.s.sol:DeployHooks \
		--rpc-url $${RPC_MAINNET} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# Install hooks on existing MetaWallet
install-hooks-localhost:
	@echo "Installing hooks on LOCALHOST..."
	@forge script script/Deploy.s.sol:InstallHooks \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

install-hooks-sepolia:
	@echo "Installing hooks on SEPOLIA..."
	@forge script script/Deploy.s.sol:InstallHooks \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

install-hooks-mainnet:
	@echo "Installing hooks on MAINNET..."
	@forge script script/Deploy.s.sol:InstallHooks \
		--rpc-url $${RPC_MAINNET} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# Format JSON output files
format-output:
	@echo "Formatting JSON output files..."
	@for file in deployments/output/*/*.json; do \
		if [ -f "$$file" ]; then \
			echo "Formatting $$file"; \
			jq . "$$file" > "$$file.tmp" && mv "$$file.tmp" "$$file"; \
		fi; \
	done
	@echo "JSON files formatted!"

# Predict proxy address
predict-address:
	@forge script script/Deploy.s.sol:PredictProxyAddress -vvvv

# Verification
verify:
	@echo "Verifying deployment..."
	@if [ ! -f "deployments/output/localhost/addresses.json" ] && [ ! -f "deployments/output/mainnet/addresses.json" ] && [ ! -f "deployments/output/sepolia/addresses.json" ]; then \
		echo "No deployment files found"; \
		exit 1; \
	fi
	@echo "Deployment files exist"
	@echo "Check deployments/output/ for contract addresses"

# Clean localhost deployment
clean:
	forge clean
	rm -f deployments/output/localhost/addresses.json

# Clean all deployments (DANGER)
clean-all:
	forge clean
	rm -f deployments/output/*/addresses.json

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD & TEST
# ═══════════════════════════════════════════════════════════════════════════════

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

## Install dependencies
install:
	forge soldeer install

## Show contract sizes
sizes:
	forge build --sizes

## Generate gas snapshot
snapshot:
	forge snapshot

## Generate documentation
docs:
	forge doc --serve --port 4000

# ═══════════════════════════════════════════════════════════════════════════════
# MULTI-CHAIN DEPLOYMENT (for L2s)
# ═══════════════════════════════════════════════════════════════════════════════

deploy-arbitrum:
	@echo "Deploying to ARBITRUM..."
	@forge script script/Deploy.s.sol:DeployAll \
		--rpc-url $${RPC_ARBITRUM} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow \
		--verify \
		--etherscan-api-key $${ARBISCAN_API_KEY}
	@$(MAKE) format-output

deploy-optimism:
	@echo "Deploying to OPTIMISM..."
	@forge script script/Deploy.s.sol:DeployAll \
		--rpc-url $${RPC_OPTIMISM} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow \
		--verify \
		--etherscan-api-key $${OPTIMISM_API_KEY}
	@$(MAKE) format-output

deploy-base:
	@echo "Deploying to BASE..."
	@forge script script/Deploy.s.sol:DeployAll \
		--rpc-url $${RPC_BASE} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow \
		--verify \
		--etherscan-api-key $${BASESCAN_API_KEY}
	@$(MAKE) format-output

deploy-polygon:
	@echo "Deploying to POLYGON..."
	@forge script script/Deploy.s.sol:DeployAll \
		--rpc-url $${RPC_POLYGON} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow \
		--verify \
		--etherscan-api-key $${POLYGONSCAN_API_KEY}
	@$(MAKE) format-output
