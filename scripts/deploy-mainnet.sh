#!/usr/bin/env bash
# ONE command to go live on Arc Mainnet once the deployer holds >= 0.05 USDC on Arc (5 USDC recommended).
#   scripts/deploy-mainnet.sh            (interactive confirm)
#   CONFIRM=deploy scripts/deploy-mainnet.sh   (non-interactive)
# What it does (each network step under `timeout`):
#   1. preflight: RPC chain-id == 5042, deployer balance >= 0.05 USDC, base fee <= 200 gwei
#   2. deploys PayPerQuery (price 0.001 USDC), then pays for one real query and runs the worker
#      verification + rejection checks against mainnet (writes deployments/mainnet.json + gate-5042.json)
#   3. writes the contract address into worker/wrangler.toml [env.mainnet]
#   4. best-effort source verification on the Arc explorer (Blockscout); non-fatal
# Expected cost at the 20 gwei floor: ~0.0135 USDC deploy + ~0.0019 USDC pay gas + 0.001 USDC price (returned via withdraw).
# It does NOT deploy the Cloudflare Worker; that is the next, separate command printed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
[ -e deployments/mainnet.json ] && { echo "deployments/mainnet.json exists; already deployed. Delete it deliberately to redeploy."; exit 1; }
ans="${CONFIRM:-}"   # non-interactive: CONFIRM=deploy scripts/deploy-mainnet.sh
[ -n "$ans" ] || read -r -p "Deploy PayPerQuery to Arc MAINNET with deployer from ~/.config/agent-income/arc-deployer.env? type 'deploy': " ans
[ "$ans" = deploy ] || { echo aborted; exit 1; }
CONFIRM_MAINNET=yes scripts/e2e.sh mainnet
python3 scripts/set_contract.py mainnet
ADDR=$(python3 -c "import json;print(json.load(open('deployments/mainnet.json'))['contract'])")
timeout 120 arc-forge verify-contract "$ADDR" src/PayPerQuery.sol:PayPerQuery --chain-id 5042 \
  --verifier blockscout --verifier-url https://explorer.arc.io/api/ \
  --constructor-args "$(arc-cast abi-encode 'constructor(uint256)' 1000000000000000)" \
  || echo "WARN: explorer verification failed (explorer may sit behind a bot challenge); verify manually at https://explorer.arc.io/address/$ADDR"
cat <<MSG

Mainnet contract: https://explorer.arc.io/address/$ADDR
Payment tx:       $(python3 -c "import json;print(json.load(open('deployments/gate-5042.json'))['payment_explorer'])")
Next (Cloudflare account action):  cd worker && npx wrangler deploy --env mainnet
Then the demo deep link is:  https://<worker-host>/$(cut -d/ -f4- deployments/deeplink-5042.txt)
MSG
