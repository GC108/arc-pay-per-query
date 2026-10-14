# Arc Pay-per-Query

**An HTTP 402 data API where AI agents pay for each call in USDC on Arc, and gas is paid in USDC too.**

An agent asks for data and gets back `402 Payment Required` with the exact transaction to send: contract, value and calldata. It sends one `pay(queryHash)` transaction on Arc and retries the request with the tx hash. The server checks the receipt on-chain and returns the records. The agent needs no API key, no account and no second gas token. It holds USDC and nothing else.

## Live on Arc Mainnet

- **Demo (no wallet needed; replays a real mainnet payment that the server re-verifies live):** https://arcpayperquery.com/?state=TX&min_employees=100&limit=3&nonce=e2e-db2f6a9ba3d46fc4&tx=0x69b5b0e38031fa65eaccb75bbea4337df26e719fa7b03a44b68682cdf0fcf4da
- **Contract:** [`0x02778880fbbad082ec9a654ae521562ebe8acf83`](https://explorer.arc.io/address/0x02778880fbbad082ec9a654ae521562ebe8acf83)
- **First paid query:** [`0x69b5b0e3…f4da`](https://explorer.arc.io/tx/0x69b5b0e38031fa65eaccb75bbea4337df26e719fa7b03a44b68682cdf0fcf4da)
- **Try the 402 yourself:** `curl -i "https://arcpayperquery.com/v1/warn?state=TX&min_employees=100&limit=3&nonce=agent-$(date +%s)"`

The dataset is a static slice of 100 official **WARN Act layoff notices** from the Texas Workforce Commission (2026 YTD) and the California EDD daily report (Jul 1–15, 2026). These are public records of factual data (company, county, headcount, dates), and each response cites its source file.

## Why Arc

- **One asset.** On Arc, USDC is the native gas token (18 decimals), so the payment and its gas are the same dollar-denominated asset. A paying agent doesn't need ETH, a swap, or a gas sponsor.
- **Finality under a second.** The server checks a receipt once and it can't be reorged, so it doesn't wait for confirmations.
- **Predictable fees.** The fee is a dollar amount: a query costs 0.001 USDC plus about 0.0019 USDC of gas at the 20 gwei floor (93k gas measured).

## How it works

```
agent                         worker (Cloudflare)                       Arc
  | GET /v1/warn?state=TX&...&nonce=N  |                                   |
  |----------------------------------->|                                   |
  | 402 {query_hash, tx:{to,value,data}}                                   |
  |<-----------------------------------|                                   |
  | pay(query_hash) {value: 0.001 USDC} ---------------------------------->|  QueryPaid(queryHash, payer, amount, id)
  | GET same URL + X-Payment-Tx: 0x..  |                                   |
  |----------------------------------->| eth_getTransactionReceipt ------->|
  |                                    | check: chainId, status, contract, |
  |                                    | QueryPaid.topic1 == keccak(query),|
  |                                    | amount >= price, age <= TTL       |
  | 200 {notices[], payment receipt}   |                                   |
  |<-----------------------------------|                                   |
```

- `queryHash = keccak256("GET /v1/warn?" + canonical params)`. Params are taken in a fixed order, unknown ones are dropped, and a `nonce` is required. A payment is therefore bound to one exact request. Changing `limit` or `state` makes the server reject the receipt.
- The contract accepts **exactly** `price` wei per query, so an agent that confuses Arc's 18-decimal native USDC with the 6-decimal ERC-20 view gets a revert instead of over- or under-paying. Each `queryHash` can be paid once. Plain transfers revert. The owner can withdraw, and ownership transfer takes two steps.
- A receipt is a bearer credential for that exact query until the TTL runs out (24 h on testnet, 30 days on mainnet so the demo link stays verifiable).

## Layout

| Path | What |
|---|---|
| `src/PayPerQuery.sol` | Receipt contract (native USDC `msg.value`) |
| `test/PayPerQuery.t.sol` | 10 Foundry tests including a 512-run fuzz (`arc-forge test --network arc`) |
| `script/Deploy.s.sol`, `script/Pay.s.sol` | Deploy and pay scripts. Keys come from the environment, never from argv |
| `worker/src/lib.js` | Worker: 402 quote, receipt verification, query |
| `worker/src/warn-data.js` | Static WARN slice (100 notices) and source citations |
| `worker/test/unit.test.mjs` | Canonicalization, keccak parity with Solidity, 400/402 paths |
| `worker/test/e2e.mjs` | The gate: quote → pay on-chain → 200, plus rejection of a fake tx, a cross-query replay, a non-payment tx, and tampered params |
| `web/index.html` | Demo page (wallet flow, plus a no-wallet deep link that replays a real paid query) |
| `scripts/e2e.sh local\|testnet\|mainnet` | Full end-to-end run (`WRANGLER=1` runs the real workerd runtime) |
| `scripts/deploy-mainnet.sh` | One-command mainnet go-live with preflight guards |
| `deployments/` | Addresses, gate results and deep links written by the scripts |

## Run it

```bash
# Arc Foundry (Arc-specific fork: arc-forge / arc-cast / arc-anvil) — https://docs.arc.io/arc/tutorials/install-arc-foundry
arc-forge test --network arc
cd worker && npm install && npm test && cd ..
WRANGLER=1 scripts/e2e.sh local          # arc-anvil --network arc + wrangler dev, full gate
scripts/e2e.sh testnet                   # Arc Testnet (needs faucet USDC on the deployer)
CONFIRM=deploy scripts/deploy-mainnet.sh # Arc Mainnet (needs ≥0.05 USDC on the deployer)
cd worker && npx wrangler deploy --env mainnet
```

Agent usage (no SDK):
```bash
curl -s "$API/v1/warn?state=TX&min_employees=100&limit=3&nonce=$N"           # -> 402 with tx {to,value,data}
cast send <to> <data> --value <value> --rpc-url https://rpc.mainnet.arc.io   # pay
curl -s -H "X-Payment-Tx: $TX" "$API/v1/warn?state=TX&min_employees=100&limit=3&nonce=$N"  # -> 200
```

## Network facts (docs.arc.io, read 2026-10-10)

| | Mainnet | Testnet |
|---|---|---|
| Chain ID | 5042 | 5042002 |
| RPC | https://rpc.mainnet.arc.io | https://rpc.testnet.arc.io |
| Explorer | https://explorer.arc.io | https://explorer.testnet.arc.io |
| Gas token | USDC, native, 18 decimals | same |
| USDC ERC-20 view | `0x3600000000000000000000000000000000000000` (6 decimals) | same |
| Min `maxFeePerGas` | 20 gwei | 20 gwei |

## Deployments

- Deployer / owner: `0x759Cf1362db92Be95f7011aB8ff1D2A2D821e67c`
- Testnet: see `deployments/testnet.json` (pending faucet funding)
- Mainnet: see `deployments/mainnet.json` (pending ~5 USDC funding)

## Limits (honest)

- Static data slice from July 2026, not a live feed. The point is the payment rail, and adding a source means adding a module.
- Receipts are bearer credentials: whoever holds the tx hash and the exact query can replay it until the TTL ends. Binding to the payer would need a signed request (EIP-191) and is the next step.
- The Worker is stateless. It does no rate limiting and doesn't track receipts beyond the chain.

License: MIT.
