// Arc pay-per-query data API (Cloudflare Worker).
// Flow: GET /v1/warn?...&nonce=X  -> 402 with exact payment instructions (queryHash + calldata)
//       agent sends PayPerQuery.pay(queryHash) with value = price (native USDC, 18 decimals)
//       GET same URL with header `X-Payment-Tx: <txHash>` -> worker verifies the receipt on Arc -> 200 + data
import { keccak_256 } from "@noble/hashes/sha3";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils";
import { NOTICES, SOURCES } from "./warn-data.js";

// keccak256("QueryPaid(bytes32,address,uint256,uint256)")
export const QUERY_PAID_TOPIC = "0x67d30c51a34efc7e931b6cde6af5cabfa60ab75f15ad411ade9a3208db7eeb1f";
// bytes4(keccak256("pay(bytes32)"))
export const PAY_SELECTOR = "0x8609cad1";

const ALLOWED_PARAMS = ["state", "min_employees", "since", "limit", "nonce"];
const NONCE_RE = /^[A-Za-z0-9_-]{8,64}$/;
const TX_RE = /^0x[0-9a-fA-F]{64}$/;

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, OPTIONS",
  "access-control-allow-headers": "x-payment-tx, content-type",
  "access-control-expose-headers": "x-query-hash",
};

function json(status, body, extra = {}) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...CORS, ...extra },
  });
}

/** Canonical request string that the on-chain payment is bound to. */
export function canonicalQuery(url) {
  const u = new URL(url);
  const pairs = [];
  for (const k of ALLOWED_PARAMS) {
    const v = u.searchParams.get(k);
    if (v !== null && v !== "") pairs.push(`${k}=${encodeURIComponent(v)}`);
  }
  return `GET ${u.pathname}?${pairs.join("&")}`;
}

export function queryHash(canonical) {
  return "0x" + bytesToHex(keccak_256(utf8ToBytes(canonical)));
}

function validate(u) {
  const p = u.searchParams;
  const nonce = p.get("nonce");
  if (!nonce || !NONCE_RE.test(nonce)) return "nonce is required: 8-64 chars of [A-Za-z0-9_-], unique per paid query";
  const state = p.get("state");
  if (state && !["TX", "CA"].includes(state)) return "state must be TX or CA";
  const min = p.get("min_employees");
  if (min && !/^\d{1,6}$/.test(min)) return "min_employees must be an integer";
  const since = p.get("since");
  if (since && !/^\d{4}-\d{2}-\d{2}$/.test(since)) return "since must be YYYY-MM-DD";
  const limit = p.get("limit");
  if (limit && !(/^\d{1,2}$/.test(limit) && +limit >= 1 && +limit <= 25)) return "limit must be 1-25";
  return null;
}

export function runQuery(u) {
  const p = u.searchParams;
  const state = p.get("state");
  const min = +(p.get("min_employees") || 0);
  const since = p.get("since") || "0000-00-00";
  const limit = +(p.get("limit") || 10);
  const rows = NOTICES.filter(
    (n) => (!state || n.state === state) && n.employees >= min && n.notice_date >= since,
  );
  return { total_matches: rows.length, notices: rows.slice(0, limit) };
}

async function rpc(env, method, params) {
  const res = await fetch(env.RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) throw new Error(`rpc ${method} http ${res.status}`);
  const body = await res.json();
  if (body.error) throw new Error(`rpc ${method}: ${body.error.message}`);
  return body.result;
}

/**
 * Verify that `txHash` is a successful PayPerQuery.pay(qh) on the configured chain/contract,
 * for at least the configured price, and not older than PAYMENT_TTL_SECONDS.
 * Returns { ok: true, receipt } or { ok: false, reason }.
 */
export async function verifyPayment(env, txHash, qh) {
  if (!TX_RE.test(txHash)) return { ok: false, reason: "X-Payment-Tx must be a 0x-prefixed 32-byte tx hash" };
  const chainId = parseInt(await rpc(env, "eth_chainId", []), 16);
  if (chainId !== Number(env.CHAIN_ID)) return { ok: false, reason: `rpc chain ${chainId} != expected ${env.CHAIN_ID}` };

  const rcpt = await rpc(env, "eth_getTransactionReceipt", [txHash]);
  if (!rcpt) return { ok: false, reason: "transaction not found on this chain" };
  if (rcpt.status !== "0x1") return { ok: false, reason: "transaction reverted" };

  const contract = env.CONTRACT_ADDRESS.toLowerCase();
  const log = rcpt.logs.find(
    (l) =>
      l.address.toLowerCase() === contract &&
      l.topics[0]?.toLowerCase() === QUERY_PAID_TOPIC &&
      l.topics[1]?.toLowerCase() === qh.toLowerCase(),
  );
  if (!log) return { ok: false, reason: "transaction contains no QueryPaid event for this query on this contract" };

  const data = log.data.slice(2);
  const amount = BigInt("0x" + data.slice(0, 64));
  const receiptId = BigInt("0x" + data.slice(64, 128));
  if (amount < BigInt(env.PRICE_WEI)) return { ok: false, reason: `paid ${amount} < price ${env.PRICE_WEI}` };

  const block = await rpc(env, "eth_getBlockByNumber", [rcpt.blockNumber, false]);
  const paidAt = parseInt(block.timestamp, 16);
  const age = Math.floor(Date.now() / 1000) - paidAt;
  if (age > Number(env.PAYMENT_TTL_SECONDS)) return { ok: false, reason: `payment is ${age}s old; TTL is ${env.PAYMENT_TTL_SECONDS}s` };

  return {
    ok: true,
    receipt: {
      tx: txHash,
      payer: "0x" + log.topics[2].slice(26),
      amount_wei: amount.toString(),
      amount_usdc: Number(amount) / 1e18,
      receipt_id: receiptId.toString(),
      block: parseInt(rcpt.blockNumber, 16),
      paid_at: new Date(paidAt * 1000).toISOString(),
      explorer: `${env.EXPLORER_URL}/tx/${txHash}`,
    },
  };
}

function paymentRequired(env, canonical, qh, reason) {
  const value = "0x" + BigInt(env.PRICE_WEI).toString(16);
  return json(
    402,
    {
      error: "payment_required",
      reason,
      payment: {
        chain_id: Number(env.CHAIN_ID),
        network: env.NETWORK_NAME,
        rpc_url: env.RPC_URL,
        contract: env.CONTRACT_ADDRESS,
        function: "pay(bytes32)",
        price_wei: env.PRICE_WEI,
        price_usdc: Number(BigInt(env.PRICE_WEI)) / 1e18,
        gas_token: "USDC (native, 18 decimals)",
        canonical_query: canonical,
        query_hash: qh,
        tx: { to: env.CONTRACT_ADDRESS, value, data: PAY_SELECTOR + qh.slice(2) },
        then: "repeat this exact GET with header X-Payment-Tx: <txHash>",
      },
    },
    { "x-query-hash": qh },
  );
}

export const handler = {
  async fetch(request, env) {
    const u = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (request.method !== "GET") return json(405, { error: "method_not_allowed" });

    if (u.pathname === "/" || u.pathname === "/v1") {
      return json(200, {
        service: "Arc pay-per-query: WARN Act layoff notices",
        how: "GET /v1/warn?state=TX&min_employees=100&limit=5&nonce=<unique> -> 402 with payment instructions -> pay on Arc -> retry with X-Payment-Tx",
        params: { state: "TX|CA", min_employees: "int", since: "YYYY-MM-DD", limit: "1-25 (default 10)", nonce: "required, unique per paid query" },
        network: env.NETWORK_NAME,
        chain_id: Number(env.CHAIN_ID),
        contract: env.CONTRACT_ADDRESS,
        price_usdc: Number(BigInt(env.PRICE_WEI)) / 1e18,
        records: NOTICES.length,
        sources: SOURCES,
      });
    }
    if (u.pathname !== "/v1/warn") return json(404, { error: "not_found" });

    const bad = validate(u);
    if (bad) return json(400, { error: "bad_request", reason: bad });

    const canonical = canonicalQuery(u);
    const qh = queryHash(canonical);
    const tx = request.headers.get("x-payment-tx");
    if (!tx) return paymentRequired(env, canonical, qh, "no X-Payment-Tx header");

    let v;
    try {
      v = await verifyPayment(env, tx.trim(), qh);
    } catch (e) {
      return json(502, { error: "rpc_unavailable", reason: String(e.message || e) });
    }
    if (!v.ok) return paymentRequired(env, canonical, qh, v.reason);

    return json(200, { query: canonical, query_hash: qh, payment: v.receipt, ...runQuery(u), sources: SOURCES });
  },
};
