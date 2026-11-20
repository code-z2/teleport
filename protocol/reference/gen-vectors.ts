// Regenerates protocol/vectors.json. Run: node protocol/reference/gen-vectors.ts
// Only regenerate when the protocol changes — Swift and Kotlin tests read this file.
import { writeFileSync } from "node:fs";
import {
  BLOB_AAD,
  aesGcm,
  b64u,
  deriveKey,
  enc,
  fingerprint,
  generateRawKeyPair,
  pairPlaintext,
  pairProof,
  seal,
  type Envelope,
  type Kind,
  type RawKeyPair,
} from "./teleport.ts";

const kp = (k: RawKeyPair) => ({ d: b64u(k.d), pub: b64u(k.pub) });
const rand = (n: number) => crypto.getRandomValues(new Uint8Array(n));

const recipientKa = await generateRawKeyPair();
const senderKs = await generateRawKeyPair();
const otherKs = await generateRawKeyPair();
const TS = 1_790_000_000;

const plaintexts: [string, Kind, string][] = [
  ["ascii text", "text", "hello from the other phone"],
  ["unicode text", "text", "héllo 👋 — 東京 🚀"],
  ["empty text", "text", ""],
  ["url", "text", "https://example.com/a?b=c&d=e#f"],
  ["peer update", "peer", JSON.stringify({ fcm: "fcm-token-abc", la: "la-token-xyz", name: "iPhone" })],
];

const cases = [];
for (const [name, k, text] of plaintexts) {
  const id = rand(16);
  const eph = await generateRawKeyPair();
  const nonce = rand(12);
  const pt = enc.encode(text);
  const env = await seal(k, pt, senderKs, recipientKa.pub, { id, ts: TS, eph, nonce });
  const key = await deriveKey(eph, eph.pub, null, recipientKa.pub);
  cases.push({ name, plaintext: b64u(pt), eph: kp(eph), derived_key: b64u(key), env });
}

// Blob: a fake 1 KB "image", envelope plaintext points at it.
const blobKey = rand(32);
const blobNonce = rand(12);
const blobBytes = rand(1024);
const blobCt = await aesGcm("encrypt", blobKey, blobNonce, blobBytes, BLOB_AAD);
const pointer = { id: "r2-object-id-123", mime: "image/png", size: blobBytes.length, key: b64u(blobKey), n: b64u(blobNonce) };
{
  const eph = await generateRawKeyPair();
  const pt = enc.encode(JSON.stringify(pointer));
  const env = await seal("blob", pt, senderKs, recipientKa.pub, { id: rand(16), ts: TS, eph, nonce: rand(12) });
  const key = await deriveKey(eph, eph.pub, null, recipientKa.pub);
  cases.push({ name: "blob pointer", plaintext: b64u(pt), eph: kp(eph), derived_key: b64u(key), env });
}

// Invalid envelopes: each must be rejected with the given error.
const base = cases[0].env as Envelope;
const flip = (s: string) => {
  const b = Buffer.from(s, "base64url");
  b[b.length - 1] ^= 0x01;
  return b64u(b);
};
const signedByOther = await seal("text", enc.encode("forged"), otherKs, recipientKa.pub, { ts: TS });
const invalid = [
  { name: "tampered ciphertext", error: "signature", env: { ...base, ct: flip(base.ct) } },
  { name: "tampered nonce", error: "signature", env: { ...base, n: flip(base.n) } },
  { name: "tampered timestamp", error: "signature", env: { ...base, ts: base.ts + 1 } },
  { name: "tampered kind", error: "signature", env: { ...base, k: "peer" } },
  { name: "wrong version", error: "version", env: { ...base, v: 2 } },
  { name: "unknown sender", error: "peer", env: signedByOther },
  { name: "forged from", error: "signature", env: { ...signedByOther, from: base.from } },
];

const card = {
  v: 1,
  name: "Pixel",
  platform: "android",
  ka: b64u(recipientKa.pub),
  ks: b64u(senderKs.pub),
  fcm: "fcm-token-abc",
};

// ---------- pairing v2 ----------
// B (scanner, keys: sender_ks + pair.b_ka) pairs with A (shows QR, keys: recipient_ka + pair.a_ks).
const aKs = await generateRawKeyPair();
const bKa = await generateRawKeyPair();
const ps = rand(16);
const bCard = JSON.stringify({ v: 2, name: "Pixel 8", platform: "android", ka: b64u(bKa.pub), ks: b64u(senderKs.pub), fcm: "fcm-b" });
const aCardQR = { v: 2, name: "Peso's iPhone", platform: "ios", ka: b64u(recipientKa.pub), ks: b64u(aKs.pub), fcm: "fcm-a", ps: b64u(ps) };
const { ps: _omit, ...aCardNoPs } = aCardQR;
const aCardJson = JSON.stringify(aCardNoPs);
const proof = await pairProof(ps, bCard);
const pairEph = await generateRawKeyPair();
const pairEnv = await seal("pair", pairPlaintext(bCard, proof), senderKs, recipientKa.pub, { id: rand(16), ts: TS, eph: pairEph, nonce: rand(12) });
const okEph = await generateRawKeyPair();
const pairOkEnv = await seal("pair-ok", enc.encode(aCardJson), aKs, bKa.pub, { id: rand(16), ts: TS, eph: okEph, nonce: rand(12) });
// Impersonation: an attacker signs with its own key but presents B's card.
const forgedCardEnv = await seal("pair", pairPlaintext(bCard, proof), otherKs, recipientKa.pub, { ts: TS });
const pairing = {
  ps: b64u(ps),
  a_ks: kp(aKs),
  b_ka: kp(bKa),
  qr: "teleport2:" + b64u(enc.encode(JSON.stringify(aCardQR))),
  b_card: bCard,
  proof: b64u(proof),
  pair: { eph: kp(pairEph), plaintext: b64u(pairPlaintext(bCard, proof)), env: pairEnv },
  pair_ok: { eph: kp(okEph), plaintext: b64u(enc.encode(aCardJson)), env: pairOkEnv },
  invalid: [
    { name: "wrong pairing secret", error: "proof", ps: b64u(rand(16)), env: pairEnv },
    { name: "tampered ciphertext", error: "decrypt", ps: b64u(ps), env: { ...pairEnv, ct: flip(pairEnv.ct) } },
    { name: "tampered signature", error: "signature", ps: b64u(ps), env: { ...pairEnv, sig: flip(pairEnv.sig) } },
    { name: "card does not match signer", error: "peer", ps: b64u(ps), env: forgedCardEnv },
    { name: "wrong kind", error: "kind", ps: b64u(ps), env: { ...pairEnv, k: "text" } },
  ],
};

const vectors = {
  comment: "Generated by protocol/reference/gen-vectors.ts — see protocol/SPEC.md. 'now' for ts checks = ts.",
  now: TS,
  recipient_ka: kp(recipientKa),
  sender_ks: { ...kp(senderKs), fp: await fingerprint(senderKs.pub) },
  cases,
  blob: { ...pointer, plaintext: b64u(blobBytes), ciphertext: b64u(blobCt) },
  invalid,
  pairing_card: { card, encoded: "teleport1:" + b64u(enc.encode(JSON.stringify(card))) },
  pairing,
};

const out = new URL("../vectors.json", import.meta.url);
writeFileSync(out, JSON.stringify(vectors, null, 2) + "\n");
console.log(`wrote ${cases.length} cases, ${invalid.length} invalid → ${out.pathname}`);
