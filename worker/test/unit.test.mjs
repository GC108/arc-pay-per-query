import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { canonicalQuery, queryHash } from "../src/lib.js";

const env = { NETWORK_NAME: "t", CHAIN_ID: "5042002", RPC_URL: "http://127.0.0.1:1", EXPLORER_URL: "x",
  CONTRACT_ADDRESS: "0x0000000000000000000000000000000000000001", PRICE_WEI: "1000000000000000", PAYMENT_TTL_SECONDS: "86400" };

test("canonical query is param-order independent and drops unknown params", () => {
  const a = canonicalQuery("https://h/v1/warn?state=TX&nonce=abc&limit=3&junk=1");
  const b = canonicalQuery("https://h/v1/warn?limit=3&state=TX&nonce=abc");
  assert.equal(a, b);
  assert.equal(a, "GET /v1/warn?state=TX&limit=3&nonce=abc");
});

test("queryHash equals Solidity keccak256 (cross-checked with arc-cast keccak)", () => {
  // arc-cast keccak 'GET /v1/warn?limit=3&nonce=abc&state=TX'
  assert.equal(queryHash("GET /v1/warn?limit=3&nonce=abc&state=TX"),
    "0x4103fe62f6f340987cd0f6ab7c69374a6ce39b03832a0635e5dcf3ea2d739837");
});

test("missing nonce -> 400; unpaid -> 402 with calldata", async () => {
  let r = await worker.fetch(new Request("https://h/v1/warn?state=TX"), env);
  assert.equal(r.status, 400);
  r = await worker.fetch(new Request("https://h/v1/warn?state=TX&nonce=abcdefgh"), env);
  assert.equal(r.status, 402);
  const b = await r.json();
  assert.equal(b.payment.tx.value, "0x38d7ea4c68000");
  assert.equal(b.payment.tx.data, "0x8609cad1" + b.payment.query_hash.slice(2));
});

test("malformed tx hash -> 402 without touching RPC", async () => {
  const r = await worker.fetch(new Request("https://h/v1/warn?nonce=abcdefgh", { headers: { "x-payment-tx": "0x1234" } }), env);
  assert.equal(r.status, 402);
});
