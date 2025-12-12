# MetaWallet Deployment Makefile
# Usage: make deploy-localhost, make deploy-mainnet, make deploy-sepolia
-include .env
export

.PHONY: help deploy-mainnet deploy-sepolia deploy-localhost deploy-all verify clean clean-all format-output

# Default target
help:
	@echo "MetaWallet Deployment Commands"
	@echo "=============================="
	@echo ""
	@echo "Production Deployment:"
	@echo "  make deploy-mainnet     - Deploy to ALL chains in mainnet.json (same address)"
	@echo "  make validate-config    - Validate mainnet.json before deployment"
	@echo "  make predict-mainnet    - Predict proxy address for mainnet deployment"
	@echo ""
	@echo "Single Chain Deployment:"
	@echo "  make deploy-localhost   - Deploy to localhost (anvil)"
	@echo "  make deploy-sepolia     - Deploy to Sepolia testnet"
	@echo ""
	@echo "Individual steps:"
	@echo "  make deploy-mocks-*     - Deploy mock assets only (00)"
	@echo "  make deploy-impl-*      - Deploy implementation + VaultModule only (01)"
	@echo "  make deploy-proxy-*     - Deploy proxy (requires impl deployed) (02)"
	@echo "  make deploy-hooks-*     - Deploy hooks (requires proxy deployed) (03)"
	@echo "  make install-hooks-*    - Install hooks on existing MetaWallet (04)"
	@echo ""
	@echo "Utilities:"
	@echo "  make verify             - Verify deployment files exist"
	@echo "  make clean              - Clean localhost deployment files"
	@echo "  make clean-all          - Clean ALL deployment files (DANGER)"
	@echo "  make format-output      - Format JSON output files"
	@echo "  make predict-address    - Predict proxy address (single chain)"
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
# MAINNET PRODUCTION DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════

# Deploy to all chains configured in mainnet.json with same address
deploy-mainnet:
	@echo "Starting mainnet deployment..."
	@./script/deploy-mainnet.sh
	@$(MAKE) format-output

# Validate mainnet config before deployment
validate-config:
	@echo "Validating mainnet.json configuration..."
	@forge script script/helpers/PredictAddress.s.sol:ValidateMainnetConfigScript -vvvv

# Predict mainnet proxy address
predict-mainnet:
	@echo "Predicting mainnet proxy address..."
	@forge script script/helpers/PredictAddress.s.sol:PredictMainnetAddressScript \
		--rpc-url $${RPC_MAINNET} \
		-vvvv

# ═══════════════════════════════════════════════════════════════════════════════
# SINGLE CHAIN DEPLOYMENTS (ALL-IN-ONE)
# ═══════════════════════════════════════════════════════════════════════════════

# Localhost deployment (uses anvil default private key - no secrets needed)
deploy-localhost:
	@echo "Deploying to LOCALHOST..."
	@forge script script/deployment/05_DeployAll.s.sol:DeployAllScript \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow
	@$(MAKE) format-output

# Sepolia deployment (uses keystore for production security)
deploy-sepolia:
	@echo "Deploying to SEPOLIA..."
	@forge script script/deployment/05_DeployAll.s.sol:DeployAllScript \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow \
		--verify \
		--etherscan-api-key $${ETHERSCAN_API_KEY}
	@$(MAKE) format-output

# ═══════════════════════════════════════════════════════════════════════════════
# STEP-BY-STEP DEPLOYMENT - LOCALHOST
# ═══════════════════════════════════════════════════════════════════════════════

# 00 - Deploy mock assets
deploy-mocks-localhost:
	@echo "[00] Deploying mock assets to LOCALHOST..."
	@forge script script/deployment/00_DeployMockAssets.s.sol:DeployMockAssetsScript \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

# 01 - Deploy implementation
deploy-impl-localhost:
	@echo "[01] Deploying implementation to LOCALHOST..."
	@forge script script/deployment/01_DeployImplementation.s.sol:DeployImplementationScript \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

# 02 - Deploy proxy
deploy-proxy-localhost:
	@echo "[02] Deploying proxy to LOCALHOST..."
	@forge script script/deployment/02_DeployProxy.s.sol:DeployProxyScript \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

# 03 - Deploy hooks
deploy-hooks-localhost:
	@echo "[03] Deploying hooks to LOCALHOST..."
	@forge script script/deployment/03_DeployHooks.s.sol:DeployHooksScript \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

# 04 - Install hooks
install-hooks-localhost:
	@echo "[04] Installing hooks on LOCALHOST..."
	@forge script script/deployment/04_InstallHooks.s.sol:InstallHooksScript \
		--rpc-url http://localhost:8545 \
		--broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
		--sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
		--slow

# ═══════════════════════════════════════════════════════════════════════════════
# STEP-BY-STEP DEPLOYMENT - SEPOLIA
# ═══════════════════════════════════════════════════════════════════════════════

# 00 - Deploy mock assets
deploy-mocks-sepolia:
	@echo "[00] Deploying mock assets to SEPOLIA..."
	@forge script script/deployment/00_DeployMockAssets.s.sol:DeployMockAssetsScript \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# 01 - Deploy implementation
deploy-impl-sepolia:
	@echo "[01] Deploying implementation to SEPOLIA..."
	@forge script script/deployment/01_DeployImplementation.s.sol:DeployImplementationScript \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# 02 - Deploy proxy
deploy-proxy-sepolia:
	@echo "[02] Deploying proxy to SEPOLIA..."
	@forge script script/deployment/02_DeployProxy.s.sol:DeployProxyScript \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# 03 - Deploy hooks
deploy-hooks-sepolia:
	@echo "[03] Deploying hooks to SEPOLIA..."
	@forge script script/deployment/03_DeployHooks.s.sol:DeployHooksScript \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--account keyDeployer \
		--sender $${DEPLOYER_ADDRESS} \
		--slow

# 04 - Install hooks
install-hooks-sepolia:
	@echo "[04] Installing hooks on SEPOLIA..."
	@forge script script/deployment/04_InstallHooks.s.sol:InstallHooksScript \
		--rpc-url $${RPC_SEPOLIA} \
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

# Predict proxy address (single chain using network config)
predict-address:
	@forge script script/helpers/PredictAddress.s.sol:PredictProxyAddressScript -vvvv

# Verification
verify:
	@echo "Verifying deployment..."
	@ls -la deployments/output/*/addresses.json 2>/dev/null || echo "No deployment files found"
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
