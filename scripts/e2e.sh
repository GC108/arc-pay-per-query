#!/usr/bin/env bash
# End-to-end gate: deploy PayPerQuery, pay for one query, verify via the worker, reject fakes.
#   scripts/e2e.sh local    -> arc-anvil --network arc (Arc-semantics local node, throwaway keys)
#   scripts/e2e.sh testnet  -> Arc Testnet (5042002), deployer key from ~/.config/agent-income/arc-deployer.env
#   scripts/e2e.sh mainnet  -> Arc Mainnet (5042); refuses unless CONFIRM_MAINNET=yes (use scripts/deploy-mainnet.sh)
# Optional: WORKER_URL=http://127.0.0.1:8787 to hit a running `wrangler dev` instead of the in-process worker.
# Every network step is bounded by `timeout`.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-local}"
export PATH="$HOME/.local/bin:$PATH"
FORGE=arc-forge; CAST=arc-cast
export PRICE_WEI="${PRICE_WEI:-1000000000000000}"   # 0.001 USDC (native, 18 decimals)

case "$MODE" in
  local)
    export RPC_URL=http://127.0.0.1:8546 CHAIN_ID=31337 EXPLORER_URL="(local)" NETWORK_NAME="arc-anvil local"
    timeout 600 arc-anvil --network arc --port 8546 --silent > /tmp/arc-anvil-e2e.log 2>&1 &
    ANVIL_PID=$!; trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do $CAST chain-id --rpc-url $RPC_URL >/dev/null 2>&1 && break; sleep 0.2; done
    # anvil's well-known dev key #0 (public, throwaway; never used on a real network)
    export ARC_DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
    ;;
  testnet|mainnet)
    if [ "$MODE" = testnet ]; then
      export RPC_URL=https://rpc.testnet.arc.io CHAIN_ID=5042002 EXPLORER_URL=https://explorer.testnet.arc.io NETWORK_NAME="Arc Testnet"
      FAUCET="get testnet USDC at https://faucet.circle.com (network: Arc Testnet)"
    else
      [ "${CONFIRM_MAINNET:-}" = yes ] || { echo "refusing mainnet without CONFIRM_MAINNET=yes"; exit 64; }
      export RPC_URL=https://rpc.mainnet.arc.io CHAIN_ID=5042 EXPLORER_URL=https://explorer.arc.io NETWORK_NAME="Arc Mainnet"
      FAUCET="send ~5 USDC on Arc mainnet (see SUBMISSION.md step A)"
    fi
    GOT=$(timeout 30 $CAST chain-id --rpc-url $RPC_URL); [ "$GOT" = "$CHAIN_ID" ] || { echo "RPC chain-id $GOT != $CHAIN_ID"; exit 1; }
    set -a; . "$HOME/.config/agent-income/arc-deployer.env"; set +a
    BAL=$(timeout 30 $CAST balance "$ARC_DEPLOYER_ADDRESS" --rpc-url $RPC_URL)
    echo "deployer $ARC_DEPLOYER_ADDRESS balance: $BAL wei ($(echo "$BAL" | awk '{printf "%.6f", $1/1e18}') USDC)"
    # need ~0.02 USDC at the 20 gwei floor (deploy ~675k gas + pay ~93k gas + 0.001 price); demand 0.05 headroom
    python3 -c "import sys; sys.exit(0 if int('$BAL') >= 5*10**16 else 1)" || { echo "UNFUNDED (<0.05 USDC): $FAUCET for $ARC_DEPLOYER_ADDRESS"; exit 2; }
    BASEFEE=$(timeout 30 $CAST base-fee --rpc-url $RPC_URL)
    python3 -c "import sys; sys.exit(0 if int('$BASEFEE') <= 200*10**9 else 1)" || { echo "base fee $BASEFEE wei > 200 gwei guard; retry later"; exit 3; }
    ;;
  *) echo "usage: $0 local|testnet"; exit 64;;
esac
export ARC_PAYER_PRIVATE_KEY="$ARC_DEPLOYER_PRIVATE_KEY"   # demo: deployer also plays the paying agent

# Deploy
timeout 180 $FORGE script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --network arc --slow >/tmp/arc-deploy-$MODE.log 2>&1 \
  || { cat /tmp/arc-deploy-$MODE.log; exit 1; }
RUN=broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json
export CONTRACT_ADDRESS=$(python3 -c "import json;print(json.load(open('$RUN'))['receipts'][0]['contractAddress'])")
export NON_PAYMENT_TX=$(python3 -c "import json;print(json.load(open('$RUN'))['receipts'][0]['transactionHash'])")
DEPLOY_GAS=$(python3 -c "import json;r=json.load(open('$RUN'))['receipts'][0];print(int(r['gasUsed'],16), int(r['effectiveGasPrice'],16))")
echo "deployed PayPerQuery at $CONTRACT_ADDRESS (deploy tx $NON_PAYMENT_TX; gasUsed, gasPrice = $DEPLOY_GAS)"
echo "on-chain price(): $(timeout 30 $CAST call "$CONTRACT_ADDRESS" 'price()(uint256)' --rpc-url "$RPC_URL")"

mkdir -p deployments
python3 - "$MODE" <<PY
import json,sys,os
mode=sys.argv[1]
if mode!="local":
    json.dump({"network":os.environ["NETWORK_NAME"],"chain_id":int(os.environ["CHAIN_ID"]),"contract":os.environ["CONTRACT_ADDRESS"],
               "deploy_tx":os.environ["NON_PAYMENT_TX"],"price_wei":os.environ["PRICE_WEI"],"deployer":os.environ.get("ARC_DEPLOYER_ADDRESS"),
               "explorer":os.environ["EXPLORER_URL"]+"/address/"+os.environ["CONTRACT_ADDRESS"]}, open(f"deployments/{mode}.json","w"), indent=2)
    print(f"wrote deployments/{mode}.json")
PY

# Optional: run the real Worker under `wrangler dev` (workerd runtime) instead of in-process
cd worker
if [ "${WRANGLER:-0}" = "1" ]; then
  setsid timeout 600 npx wrangler dev --port 8787 --ip 127.0.0.1 \
    --var "CONTRACT_ADDRESS:$CONTRACT_ADDRESS" --var "RPC_URL:$RPC_URL" --var "CHAIN_ID:$CHAIN_ID" \
    --var "EXPLORER_URL:$EXPLORER_URL" --var "NETWORK_NAME:$NETWORK_NAME" --var "PRICE_WEI:$PRICE_WEI" \
    < /dev/null > /tmp/arc-wrangler-$MODE.log 2>&1 &
  WR_PID=$!; trap 'kill -- -${WR_PID} ${ANVIL_PID:-} 2>/dev/null || true' EXIT   # setsid => own process group
  for _ in $(seq 1 120); do curl -s -o /dev/null http://127.0.0.1:8787/ && break; sleep 0.5; done
  export WORKER_URL=http://127.0.0.1:8787
  echo "wrangler dev up at $WORKER_URL"
fi

# Pay + verify + negative cases (bounded)
FORGE_BIN=$FORGE timeout 300 node test/e2e.mjs
# Optional browser check of the demo page while the stack is still up (e.g. POST_HOOK='python3 ../scripts/check_demo.py')
if [ "$MODE" = testnet ]; then python3 ../scripts/set_contract.py testnet; fi
if [ -n "${POST_HOOK:-}" ]; then timeout 180 bash -c "$POST_HOOK"; fi
