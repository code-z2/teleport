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
  openPair,
  pairPlaintext,
  pairProof,
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

// ---------- pairing v2 ----------
const P = V.pairing;
const aKs = raw(P.a_ks);
const bKa = raw(P.b_ka);

test("pair proof", async () => {
  assert.equal(b64u(await pairProof(unb64u(P.ps), P.b_card)), P.proof);
});

test("pair: open with the QR secret", async () => {
  const opened = await openPair(P.pair.env, recipientKa, unb64u(P.ps), V.now);
  assert.equal(opened.cardJson, P.b_card);
  assert.equal(opened.card.name, "Pixel 8");
});

test("pair: seal is deterministic given inputs", async () => {
  const eph = raw(P.pair.eph);
  const env = await seal("pair", pairPlaintext(P.b_card, unb64u(P.proof)), senderKs, recipientKa.pub, {
    id: unb64u(P.pair.env.id), ts: P.pair.env.ts, eph, nonce: unb64u(P.pair.env.n),
  });
  assert.equal(b64u(pairPlaintext(P.b_card, unb64u(P.proof))), P.pair.plaintext);
  assert.deepEqual({ ...env, sig: "" }, { ...P.pair.env, sig: "" });
});

test("pair-ok: opens with A's ks from the QR", async () => {
  const pt = await open(P.pair_ok.env, bKa, aKs.pub, V.now);
  assert.equal(b64u(pt), P.pair_ok.plaintext);
});

test("qr card v2 carries the secret", () => {
  const card = JSON.parse(Buffer.from(P.qr.slice("teleport2:".length), "base64url").toString());
  assert.equal(card.v, 2);
  assert.equal(card.ps, P.ps);
});

for (const c of P.invalid) {
  test(`pair reject: ${c.name}`, async () => {
    await assert.rejects(openPair(c.env, recipientKa, unb64u(c.ps), V.now), (e: unknown) => {
      assert.ok(e instanceof OpenError);
      assert.equal(e.code, c.error);
      return true;
    });
  });
}

// ---------- file sessions ----------
import {
  acceptTranscript,
  checkPath,
  ecdsaVerify,
  helloTranscript,
  openFrame,
  sealFrame,
  sessionKeys,
} from "./teleport.ts";

const sv = JSON.parse(readFileSync(new URL("../vectors.json", import.meta.url), "utf8"));

test("session: signatures verify against the device keys", async () => {
  const s = sv.session;
  const helloT = helloTranscript(s.mailbox, s.hello);
  assert.equal(s.hello.from, await fingerprint(unb64u(sv.sender_ks.pub)));
  assert.ok(await ecdsaVerify(unb64u(sv.sender_ks.pub), unb64u(s.hello.sig), helloT));
  const acceptT = acceptTranscript(helloT, s.accept);
  assert.equal(b64u(acceptT), s.accept_transcript);
  assert.ok(await ecdsaVerify(unb64u(s.mac_ks.pub), unb64u(s.accept.sig), acceptT));
  // A hello for a different mailbox must not verify.
  assert.ok(!(await ecdsaVerify(unb64u(sv.sender_ks.pub), unb64u(s.hello.sig), helloTranscript("otherMailbx", s.hello))));
});

test("session: both sides derive the same keys", async () => {
  const s = sv.session;
  const acceptT = unb64u(s.accept_transcript);
  const phone = await sessionKeys(raw(s.phone_eph), unb64u(s.accept.epk), acceptT);
  const mac = await sessionKeys(raw(s.mac_eph), unb64u(s.hello.epk), acceptT);
  assert.equal(b64u(phone.p2m), s.k_p2m);
  assert.equal(b64u(mac.m2p), s.k_m2p);
  assert.equal(b64u(phone.m2p), b64u(mac.m2p));
});

test("session: frames", async () => {
  const s = sv.session;
  for (const f of s.frames) {
    const key = unb64u(f.dir === 1 ? s.k_p2m : s.k_m2p);
    assert.equal(b64u(await sealFrame(key, f.dir, f.counter, unb64u(f.plaintext))), f.frame);
    assert.equal(b64u(await openFrame(key, f.dir, f.counter, unb64u(f.frame))), f.plaintext);
    // Wrong counter or direction fails.
    await assert.rejects(openFrame(key, f.dir, f.counter + 1, unb64u(f.frame)));
    await assert.rejects(openFrame(key, 3 - f.dir, f.counter, unb64u(f.frame)));
  }
});

test("session: path rules", () => {
  for (const p of sv.session.paths) assert.equal(checkPath(p.path, p.hidden), p.ok, p.path);
});

// ---------- chunked blobs ----------
import { openBlobChunked, sealBlobChunked } from "./teleport.ts";

test("chunked blobs: seal matches, open round-trips", async () => {
  const c = sv.chunked;
  for (const k of c.cases) {
    const plain = unb64u(k.plaintext);
    assert.equal(b64u(await sealBlobChunked(plain, unb64u(c.key), unb64u(c.n), c.c)), k.ciphertext, k.name);
    assert.equal(b64u(await openBlobChunked(unb64u(k.ciphertext), unb64u(c.key), unb64u(c.n), plain.length, c.c)), k.plaintext, k.name);
  }
});

test("chunked blobs: truncation, reordering and a wrong size are rejected", async () => {
  const c = sv.chunked;
  const k = c.cases[0]; // 25 bytes in chunks of 10: 26 + 26 + 21 bytes of ciphertext
  const ct = unb64u(k.ciphertext);
  const key = unb64u(c.key), n = unb64u(c.n);
  // Dropping the last chunk and claiming 20 bytes: chunk 1 isn't marked final.
  await assert.rejects(openBlobChunked(ct.subarray(0, 52), key, n, 20, c.c));
  // Swapping the first two chunks.
  const swapped = new Uint8Array([...ct.subarray(26, 52), ...ct.subarray(0, 26), ...ct.subarray(52)]);
  await assert.rejects(openBlobChunked(swapped, key, n, 25, c.c));
  // Wrong declared size.
  await assert.rejects(openBlobChunked(ct, key, n, 24, c.c));
});
