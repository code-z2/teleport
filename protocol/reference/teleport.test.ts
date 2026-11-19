// Checks the reference implementation against vectors.json.
// Run: node --test protocol/reference/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  BLOB_AAD,
  OpenError,
  aesGcm,
  b64u,
  deriveKey,
  fingerprint,
  open,
  seal,
  unb64u,
  type Envelope,
} from "./teleport.ts";

const V = JSON.parse(readFileSync(new URL("../vectors.json", import.meta.url), "utf8"));
const raw = (k: { d: string; pub: string }) => ({ d: unb64u(k.d), pub: unb64u(k.pub) });
const recipientKa = raw(V.recipient_ka);
const senderKs = raw(V.sender_ks);

test("fingerprint", async () => {
  assert.equal(await fingerprint(senderKs.pub), V.sender_ks.fp);
});

for (const c of V.cases) {
  test(`open: ${c.name}`, async () => {
    const pt = await open(c.env, recipientKa, senderKs.pub, V.now);
    assert.equal(b64u(pt), c.plaintext);
  });

  test(`seal is deterministic given inputs: ${c.name}`, async () => {
    const eph = raw(c.eph);
    assert.equal(b64u(await deriveKey(eph, eph.pub, null, recipientKa.pub)), c.derived_key);
    const env: Envelope = await seal(c.env.k, unb64u(c.plaintext), senderKs, recipientKa.pub, {
      id: unb64u(c.env.id),
      ts: c.env.ts,
      eph,
      nonce: unb64u(c.env.n),
    });
    // ECDSA signatures are randomized, so compare everything except sig.
    assert.deepEqual({ ...env, sig: "" }, { ...c.env, sig: "" });
  });
}

for (const c of V.invalid) {
  test(`reject: ${c.name}`, async () => {
    await assert.rejects(open(c.env, recipientKa, senderKs.pub, V.now), (e: unknown) => {
      assert.ok(e instanceof OpenError);
      assert.equal(e.code, c.error);
      return true;
    });
  });
}

test("stale timestamp rejected", async () => {
  await assert.rejects(open(V.cases[0].env, recipientKa, senderKs.pub, V.now + 2 * 86400), /stale/);
});

test("blob decrypts", async () => {
  const pt = await aesGcm("decrypt", unb64u(V.blob.key), unb64u(V.blob.n), unb64u(V.blob.ciphertext), BLOB_AAD);
  assert.equal(b64u(pt), V.blob.plaintext);
});

test("pairing card encodes", () => {
  const json = Buffer.from(V.pairing_card.encoded.slice("teleport1:".length), "base64url").toString();
  assert.deepEqual(JSON.parse(json), V.pairing_card.card);
});
