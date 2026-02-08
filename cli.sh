#!/usr/bin/env bash
# CLI for PrivacySwapHook - real swap testing
# Usage: ./cli.sh <command> [options]

set -e

RPC="${RPC_URL:-http://localhost:8545}"
PK="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

cmd_help() {
  cat << 'EOF'
PrivacySwapHook CLI - Real swap testing

Commands:
  local       Run full flow on local Anvil (deploy + init + swap)
  testnet     Run full flow on Unichain Sepolia (deploy + init + swap)
  testnet-privacy  Run privacy flow on Unichain Sepolia (intent submit → deferred execute)
  deploy-swap Deploy fresh contracts + add liquidity (run BEFORE each swap when you're the only LP)
  swap        Execute swap (requires env: POOL_MANAGER, SWAP_ROUTER, TOKEN0, TOKEN1, HOOK)
  deploy      Deploy hook only (for Unichain Sepolia)

Env vars:
  RPC_URL     RPC endpoint (default: http://localhost:8545)
  PRIVATE_KEY Deployer key (default: Anvil account #0)
  SWAP_AMOUNT For swap command (default: 100e18)
  USE_PRIVACY For swap command: true/false (default: true)

Examples:
  # Terminal 1: start Anvil
  anvil

  # Terminal 2: full local flow
  ./cli.sh local

  # Swap with existing deployment
  export POOL_MANAGER=0x... SWAP_ROUTER=0x... TOKEN0=0x... TOKEN1=0x... HOOK=0x...
  ./cli.sh swap

  # Full testnet flow (Unichain Sepolia) - needs WETH/USDC, bridge first
  PRIVATE_KEY=0x... ./cli.sh testnet

  # Privacy flow: submit intent, execute in next block (timing + routing privacy)
  PRIVATE_KEY=0x... ./cli.sh testnet-privacy

  # Deploy fresh before EACH swap (single-LP mode - pool gets consumed after swap)
  PRIVATE_KEY=0x... ./cli.sh deploy-swap
  # Then run testnet-privacy or ExecuteIntent.s.sol to submit + execute

  # Deploy hook only
  PRIVATE_KEY=0x... ./cli.sh deploy
EOF
}

cmd_local() {
  echo ">>> Running full local flow on $RPC"
  forge script script/LocalSwap.s.sol \
    --rpc-url "$RPC" \
    --broadcast \
    --private-key "$PK"
}

cmd_swap() {
  for v in POOL_MANAGER SWAP_ROUTER TOKEN0 TOKEN1 HOOK; do
    if [ -z "${!v}" ]; then
      echo "Error: $v not set. Run 'local' first or export addresses."
      exit 1
    fi
  done
  echo ">>> Executing swap on $RPC"
  forge script script/ExecuteSwap.s.sol \
    --rpc-url "$RPC" \
    --broadcast \
    --private-key "$PK"
}

cmd_testnet() {
  echo ">>> Running full flow on Unichain Sepolia"
  echo ">>> Ensure you have WETH + USDC (bridge from Sepolia: https://app.uniswap.org)"
  RPC_URL=https://sepolia.unichain.org forge script script/TestnetSwap.s.sol \
    --rpc-url https://sepolia.unichain.org \
    --broadcast \
    --private-key "$PK"
  echo ""
  echo ">>> View on explorer:"
  echo "    Uniscan:     https://sepolia.uniscan.xyz/"
  echo "    Blockscout:  https://unichain-sepolia.blockscout.com/"
  echo "    (Chain ID 1301 - Unichain Sepolia, NOT Ethereum Sepolia)"
  echo ""
  echo ">>> Broadcast saved to: broadcast/TestnetSwap.s.sol/1301/run-latest.json"
  echo ">>> Cache saved to:     cache/TestnetSwap.s.sol/1301/run-latest.json"
}

cmd_testnet_privacy() {
  echo ">>> Running privacy flow on Unichain Sepolia (intent → deferred execute)"
  echo ">>> Ensure you have WETH + USDC (bridge from Sepolia)"
  RPC_URL=https://sepolia.unichain.org forge script script/TestnetPrivacyFlow.s.sol \
    --rpc-url https://sepolia.unichain.org \
    --broadcast \
    --private-key "$PK"
  echo ""
  echo ">>> View on explorer: https://sepolia.uniscan.xyz/"
}

cmd_deploy_swap() {
  echo ">>> Deploying fresh contracts + pool + liquidity (Unichain Sepolia)"
  echo ">>> Run this BEFORE each swap when you're the only LP"
  RPC_URL=https://sepolia.unichain.org forge script script/DeployAndPrepareSwap.s.sol \
    --rpc-url https://sepolia.unichain.org \
    --broadcast \
    --private-key "$PK"
  echo ""
  echo ">>> Run testnet-privacy to submit + execute, or use ExecuteIntent.s.sol with the printed addresses."
}

cmd_deploy() {
  echo ">>> Deploying PrivacySwapHook (Unichain Sepolia)"
  forge script script/DeployPrivacySwapHook.s.sol \
    --rpc-url "${RPC:-https://sepolia.unichain.org}" \
    --broadcast \
    --private-key "$PK"
}

case "${1:-help}" in
  help|--help|-h) cmd_help ;;
  local)          cmd_local ;;
  testnet)        cmd_testnet ;;
  testnet-privacy) cmd_testnet_privacy ;;
  deploy-swap)    cmd_deploy_swap ;;
  swap)           cmd_swap ;;
  deploy)         cmd_deploy ;;
  *)              echo "Unknown command: $1"; cmd_help; exit 1 ;;
esac
