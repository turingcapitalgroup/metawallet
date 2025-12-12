#!/bin/bash
# Multi-chain deployment script for MetaWallet
# Reads chains from deployments/config/mainnet.json and deploys to each sequentially
# All deployments use the same salt to achieve same proxy address across chains

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CONFIG_FILE="deployments/config/mainnet.json"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  MetaWallet Multi-Chain Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: sudo pacman -S jq (Arch) or brew install jq (macOS)"
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Parse chains from config
CHAIN_COUNT=$(jq '.chains | length' $CONFIG_FILE)
echo -e "${YELLOW}Found $CHAIN_COUNT chains to deploy${NC}"
echo ""

# Validate config first
echo -e "${BLUE}Validating configuration...${NC}"
forge script script/Deploy.s.sol:ValidateMultiChainConfig -vvvv 2>/dev/null || {
    echo -e "${RED}Configuration validation failed!${NC}"
    exit 1
}
echo -e "${GREEN}Configuration validated successfully${NC}"
echo ""

# Predict address
echo -e "${BLUE}Predicting proxy address...${NC}"
FIRST_CHAIN_RPC=$(jq -r '.chains[0].rpcEnvVar' $CONFIG_FILE)
FIRST_RPC_URL=$(eval echo \$$FIRST_CHAIN_RPC)
if [ -n "$FIRST_RPC_URL" ]; then
    forge script script/Deploy.s.sol:PredictMultiChainAddress --rpc-url $FIRST_RPC_URL -vvvv 2>/dev/null || true
fi
echo ""

# Confirmation prompt
echo -e "${YELLOW}WARNING: This will deploy to $CHAIN_COUNT chains.${NC}"
echo -e "${YELLOW}Make sure you have:${NC}"
echo -e "  1. Configured your keystore (cast wallet import keyDeployer --interactive)"
echo -e "  2. Set DEPLOYER_ADDRESS in .env"
echo -e "  3. Set RPC URLs for all chains in .env"
echo -e "  4. Funded deployer address on all chains"
echo ""
read -p "Continue with deployment? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

# Track results
SUCCESSFUL_CHAINS=()
FAILED_CHAINS=()

# Deploy to each chain
for ((i=0; i<$CHAIN_COUNT; i++)); do
    CHAIN_NAME=$(jq -r ".chains[$i].name" $CONFIG_FILE)
    CHAIN_ID=$(jq -r ".chains[$i].chainId" $CONFIG_FILE)
    RPC_ENV_VAR=$(jq -r ".chains[$i].rpcEnvVar" $CONFIG_FILE)
    ETHERSCAN_ENV_VAR=$(jq -r ".chains[$i].etherscanApiKeyEnvVar" $CONFIG_FILE)
    VERIFY=$(jq -r ".chains[$i].verify" $CONFIG_FILE)

    # Get actual RPC URL from environment
    RPC_URL=$(eval echo \$$RPC_ENV_VAR)
    ETHERSCAN_KEY=$(eval echo \$$ETHERSCAN_ENV_VAR)

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Deploying to $CHAIN_NAME (Chain ID: $CHAIN_ID)${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ -z "$RPC_URL" ]; then
        echo -e "${RED}Error: RPC URL not set for $RPC_ENV_VAR${NC}"
        FAILED_CHAINS+=("$CHAIN_NAME (missing RPC)")
        continue
    fi

    # Create output directory
    mkdir -p "deployments/output/$CHAIN_NAME"

    # Build deploy command
    DEPLOY_CMD="forge script script/Deploy.s.sol:DeployMultiChain \
        --rpc-url $RPC_URL \
        --broadcast \
        --account keyDeployer \
        --sender \${DEPLOYER_ADDRESS} \
        --slow"

    # Add verification if enabled
    if [ "$VERIFY" = "true" ] && [ -n "$ETHERSCAN_KEY" ]; then
        DEPLOY_CMD="$DEPLOY_CMD --verify --etherscan-api-key $ETHERSCAN_KEY"
    fi

    # Execute deployment
    echo "Executing: $DEPLOY_CMD"
    if eval $DEPLOY_CMD; then
        echo -e "${GREEN}Successfully deployed to $CHAIN_NAME${NC}"
        SUCCESSFUL_CHAINS+=("$CHAIN_NAME")

        # Format output JSON
        if [ -f "deployments/output/$CHAIN_NAME/addresses.json" ]; then
            jq . "deployments/output/$CHAIN_NAME/addresses.json" > "deployments/output/$CHAIN_NAME/addresses.json.tmp"
            mv "deployments/output/$CHAIN_NAME/addresses.json.tmp" "deployments/output/$CHAIN_NAME/addresses.json"
        fi
    else
        echo -e "${RED}Failed to deploy to $CHAIN_NAME${NC}"
        FAILED_CHAINS+=("$CHAIN_NAME")
    fi
done

# Print summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}        DEPLOYMENT SUMMARY${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ ${#SUCCESSFUL_CHAINS[@]} -gt 0 ]; then
    echo -e "${GREEN}Successful deployments (${#SUCCESSFUL_CHAINS[@]}):${NC}"
    for chain in "${SUCCESSFUL_CHAINS[@]}"; do
        echo -e "  ${GREEN}✓${NC} $chain"
    done
fi

if [ ${#FAILED_CHAINS[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed deployments (${#FAILED_CHAINS[@]}):${NC}"
    for chain in "${FAILED_CHAINS[@]}"; do
        echo -e "  ${RED}✗${NC} $chain"
    done
fi

echo ""
echo -e "${BLUE}========================================${NC}"

# Exit with error if any deployments failed
if [ ${#FAILED_CHAINS[@]} -gt 0 ]; then
    exit 1
fi

echo -e "${GREEN}All deployments completed successfully!${NC}"
