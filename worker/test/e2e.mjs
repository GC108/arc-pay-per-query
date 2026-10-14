// End-to-end gate: 402 quote -> on-chain pay (forge script, key from env) -> worker verifies -> data.
// Negative cases: fake tx hash, real payment replayed against a different query, non-payment tx.
//
// Required env: RPC_URL CHAIN_ID CONTRACT_ADDRESS PRICE_WEI EXPLORER_URL ARC_PAYER_PRIVATE_KEY
// Optional env: WORKER_URL (e.g. http://127.0.0.1:8787 from `wrangler dev`); default = in-process worker.
//               NON_PAYMENT_TX (a successful tx that is NOT a pay() call, e.g. the deploy tx)
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import worker from "../src/index.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const env = {
  NETWORK_NAME: process.env.NETWORK_NAME || "Arc Testnet",
  CHAIN_ID: process.env.CHAIN_ID,
  RPC_URL: process.env.RPC_URL,
  EXPLORER_URL: process.env.EXPLORER_URL,
  CONTRACT_ADDRESS: process.env.CONTRACT_ADDRESS,
  PRICE_WEI: process.env.PRICE_WEI,
  PAYMENT_TTL_SECONDS: process.env.PAYMENT_TTL_SECONDS || "86400",
};
for (const [k, v] of Object.entries(env)) if (!v) throw new Error(`missing env ${k}`);

const BASE = process.env.WORKER_URL || "http://worker.local";
async function get(pathAndQuery, tx) {
  const headers = tx ? { "x-payment-tx": tx } : {};
  const req = new Request(BASE + pathAndQuery, { headers });
  const res = process.env.WORKER_URL ? await fetch(req) : await worker.fetch(req, env);
  return { status: res.status, body: await res.json() };
}

const results = [];
function check(name, cond, detail) {
  results.push({ name, pass: !!cond, detail });
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
}

function payOnChain(queryHash) {
  const r = spawnSync(
    process.env.FORGE_BIN || "arc-forge",
    ["script", "script/Pay.s.sol:Pay", "--rpc-url", env.RPC_URL, "--broadcast", "--network", "arc", "--slow"],
    { cwd: ROOT, env: { ...process.env, QUERY_HASH: queryHash }, encoding: "utf8", timeout: 180_000 },
  );
  if (r.status !== 0) throw new Error("pay script failed:\n" + r.stdout + r.stderr);
  const run = JSON.parse(readFileSync(path.join(ROOT, "broadcast/Pay.s.sol", env.CHAIN_ID, "run-latest.json"), "utf8"));
  return run.receipts[0].transactionHash;
}

const nonce = "e2e-" + randomBytes(8).toString("hex");
const q = `/v1/warn?state=TX&min_employees=100&limit=3&nonce=${nonce}`;

// 0. When running against wrangler dev, the demo page must be served at /
if (process.env.WORKER_URL) {
  const r = await fetch(process.env.WORKER_URL + "/");
  const html = await r.text();
  check("demo page served at / (static assets)", r.status === 200 && html.includes("Pay-per-query data for AI agents"), r.headers.get("content-type"));
  const d = await fetch(process.env.WORKER_URL + "/v1");
  check("service description at /v1", d.status === 200 && (await d.json()).contract?.toLowerCase() === env.CONTRACT_ADDRESS.toLowerCase());
}

// 1. Unpaid request -> 402 with exact payment instructions
const quote = await get(q);
check("unpaid request returns 402", quote.status === 402, quote.body.reason);
const p = quote.body.payment;
check("402 carries pay(bytes32) calldata bound to the query", p?.tx?.data === "0x8609cad1" + p?.query_hash?.slice(2), p?.canonical_query);

// 2. Pay on-chain
const txHash = payOnChain(p.query_hash);
console.log(`payment tx: ${txHash}  ${env.EXPLORER_URL}/tx/${txHash}`);

// 3. Paid request -> 200 + data
const paid = await get(q, txHash);
check("paid request returns 200 with data", paid.status === 200 && paid.body.notices?.length > 0,
  `${paid.body.notices?.length} notices, payer ${paid.body.payment?.payer}, receipt #${paid.body.payment?.receipt_id}`);
if (paid.status === 200) console.log("first record:", JSON.stringify(paid.body.notices[0]));

// 4. Fake tx hash -> rejected
const fake = "0x" + randomBytes(32).toString("hex");
const f = await get(q, fake);
check("fake tx hash rejected (402)", f.status === 402, f.body.reason);

// 5. Real payment replayed for a different query (different nonce) -> rejected
const other = `/v1/warn?state=CA&limit=25&nonce=${nonce}-x`;
const o = await get(other, txHash);
check("payment for query A rejected for query B (402)", o.status === 402, o.body.reason);

// 6. Successful tx that is not a pay() -> rejected
if (process.env.NON_PAYMENT_TX) {
  const n = await get(q, process.env.NON_PAYMENT_TX);
  check("non-payment tx rejected (402)", n.status === 402, n.body.reason);
}

// 7. Tampered query params with a valid payment -> rejected (limit changed)
const t = await get(q.replace("limit=3", "limit=25"), txHash);
check("valid payment with tampered params rejected (402)", t.status === 402, t.body.reason);

const failed = results.filter((r) => !r.pass);
const summary = { gate: failed.length ? "FAIL" : "PASS", at: new Date().toISOString(), network: env.NETWORK_NAME, chain_id: env.CHAIN_ID,
  contract: env.CONTRACT_ADDRESS, payment_tx: txHash, payment_explorer: `${env.EXPLORER_URL}/tx/${txHash}`,
  sample_record: paid.body.notices?.[0] ?? null, checks: results };
mkdirSync(path.join(ROOT, "deployments"), { recursive: true });
writeFileSync(path.join(ROOT, "deployments", `gate-${env.CHAIN_ID}.json`), JSON.stringify(summary, null, 2));
console.log(JSON.stringify({ gate: failed.length ? "FAIL" : "PASS", chain_id: env.CHAIN_ID, contract: env.CONTRACT_ADDRESS, payment_tx: txHash, checks: results.length, failed: failed.length }));
const deep = new URL(q, process.env.WORKER_URL || "https://WORKER_HOST"); deep.searchParams.set("tx", txHash);
writeFileSync(path.join(ROOT, "deployments", `deeplink-${env.CHAIN_ID}.txt`), deep.origin + "/" + deep.search + "\n");
console.log("demo deep link (no wallet needed):", deep.origin + "/" + deep.search);
process.exit(failed.length ? 1 : 0);
