// Teleport protocol v1 — TypeScript reference implementation (WebCrypto).
// Used to generate and check protocol/vectors.json. See protocol/SPEC.md.

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();

export type Kind = "text" | "blob" | "peer" | "pair" | "pair-ok" | "pair-no";
export const KINDS: readonly Kind[] = ["text", "blob", "peer", "pair", "pair-ok", "pair-no"];
export const MAX_ENVELOPE_BYTES = 3000;

export interface Envelope {
  v: 1;
  id: string;
  ts: number;
  k: Kind;
  from: string;
  epk: string;
  n: string;
  ct: string;
  sig: string;
}

// ---------- encoding ----------

export function b64u(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

export function unb64u(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, "base64url"));
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

export function header(id: string, ts: number, k: Kind, from: string): Uint8Array {
  return enc.encode(`teleport/v1|${id}|${ts}|${k}|${from}`);
}

export async function fingerprint(pub: Uint8Array): Promise<string> {
  const h = new Uint8Array(await subtle.digest("SHA-256", pub));
  return b64u(h.slice(0, 8));
}

// ---------- keys ----------

export interface RawKeyPair {
  d: Uint8Array; // 32-byte private scalar
  pub: Uint8Array; // 65-byte uncompressed point
}

export async function generateRawKeyPair(): Promise<RawKeyPair> {
  const kp = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const jwk = await subtle.exportKey("jwk", kp.privateKey);
  const pub = new Uint8Array(await subtle.exportKey("raw", kp.publicKey));
  return { d: unb64u(jwk.d!), pub };
}

function jwkFor(kp: RawKeyPair): JsonWebKey {
  return {
    kty: "EC",
    crv: "P-256",
    d: b64u(kp.d),
    x: b64u(kp.pub.slice(1, 33)),
    y: b64u(kp.pub.slice(33, 65)),
  };
}

const importEcdhPriv = (kp: RawKeyPair) =>
  subtle.importKey("jwk", jwkFor(kp), { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
const importEcdhPub = (pub: Uint8Array) =>
  subtle.importKey("raw", pub, { name: "ECDH", namedCurve: "P-256" }, false, []);
const importSignPriv = (kp: RawKeyPair) =>
  subtle.importKey("jwk", jwkFor(kp), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
const importVerifyPub = (pub: Uint8Array) =>
  subtle.importKey("raw", pub, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);

// ---------- primitives ----------

export async function deriveKey(
  ephPriv: RawKeyPair | null,
  ephPub: Uint8Array,
  ownKa: RawKeyPair | null,
  recipientKaPub: Uint8Array,
): Promise<Uint8Array> {
  // Sender: ECDH(ephPriv, recipientKa). Recipient: ECDH(ownKa, ephPub). Same secret.
  const [priv, pub] = ephPriv ? [ephPriv, recipientKaPub] : [ownKa!, ephPub];
  const ss = await subtle.deriveBits(
    { name: "ECDH", public: await importEcdhPub(pub) },
    await importEcdhPriv(priv),
    256,
  );
  const ikm = await subtle.importKey("raw", ss, "HKDF", false, ["deriveBits"]);
  const k = await subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: concat(ephPub, recipientKaPub),
      info: enc.encode("teleport/v1/aes-256-gcm"),
    },
    ikm,
    256,
  );
  return new Uint8Array(k);
}

export async function aesGcm(
  mode: "encrypt" | "decrypt",
  key: Uint8Array,
  nonce: Uint8Array,
  data: Uint8Array,
  aad: Uint8Array,
): Promise<Uint8Array> {
  const k = await subtle.importKey("raw", key, "AES-GCM", false, [mode]);
  const out = await subtle[mode]({ name: "AES-GCM", iv: nonce, additionalData: aad }, k, data);
  return new Uint8Array(out);
}

// ---------- seal / open ----------

export interface SealOptions {
  // Deterministic inputs for test vectors. Omit in real use.
  id?: Uint8Array;
  ts?: number;
  eph?: RawKeyPair;
  nonce?: Uint8Array;
}

export async function seal(
  kind: Kind,
  plaintext: Uint8Array,
  senderKs: RawKeyPair,
  recipientKaPub: Uint8Array,
  opts: SealOptions = {},
): Promise<Envelope> {
  const id = b64u(opts.id ?? crypto.getRandomValues(new Uint8Array(16)));
  const ts = opts.ts ?? Math.floor(Date.now() / 1000);
  const eph = opts.eph ?? (await generateRawKeyPair());
  const n = opts.nonce ?? crypto.getRandomValues(new Uint8Array(12));
  const from = await fingerprint(senderKs.pub);
  const h = header(id, ts, kind, from);
  const key = await deriveKey(eph, eph.pub, null, recipientKaPub);
  const ct = await aesGcm("encrypt", key, n, plaintext, h);
  const sig = new Uint8Array(
    await subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await importSignPriv(senderKs),
      concat(h, eph.pub, n, ct),
    ),
  );
  return { v: 1, id, ts, k: kind, from, epk: b64u(eph.pub), n: b64u(n), ct: b64u(ct), sig: b64u(sig) };
}

export type OpenErrorCode = "version" | "kind" | "peer" | "signature" | "stale" | "decrypt" | "encoding" | "proof";

export class OpenError extends Error {
  readonly code: OpenErrorCode;
  constructor(code: OpenErrorCode) {
    super(code);
    this.code = code;
  }
}

export async function open(
  env: Envelope,
  ownKa: RawKeyPair,
  senderKsPub: Uint8Array,
  now = Math.floor(Date.now() / 1000),
): Promise<Uint8Array> {
  if (env.v !== 1) throw new OpenError("version");
  if (!KINDS.includes(env.k)) throw new OpenError("kind");
  if (env.from !== (await fingerprint(senderKsPub))) throw new OpenError("peer");
  const h = header(env.id, env.ts, env.k, env.from);
  const epk = unb64u(env.epk);
  const n = unb64u(env.n);
  const ct = unb64u(env.ct);
  const ok = await subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    await importVerifyPub(senderKsPub),
    unb64u(env.sig),
    concat(h, epk, n, ct),
  );
  if (!ok) throw new OpenError("signature");
  if (env.ts < now - 86400 || env.ts > now + 300) throw new OpenError("stale");
  const key = await deriveKey(null, epk, ownKa, ownKa.pub);
  try {
    return await aesGcm("decrypt", key, n, ct, h);
  } catch {
    throw new OpenError("decrypt");
  }
}

export const BLOB_AAD = enc.encode("teleport/v1/blob");

// ---------- pairing v2 (SPEC.md "v2 additions") ----------

export async function pairProof(ps: Uint8Array, cardJson: string): Promise<Uint8Array> {
  const key = await subtle.importKey("raw", ps, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await subtle.sign("HMAC", key, enc.encode(cardJson)));
}

export function pairPlaintext(cardJson: string, proof: Uint8Array): Uint8Array {
  return enc.encode(JSON.stringify({ card: cardJson, proof: b64u(proof) }));
}

export interface OpenedPair {
  card: Record<string, unknown> & { ks: string; name: string };
  cardJson: string;
  proof: Uint8Array;
}

/** Opens a `pair` envelope from a not-yet-known device. Checks the proof against `ps`. */
export async function openPair(
  env: Envelope,
  ownKa: RawKeyPair,
  ps: Uint8Array,
  now = Math.floor(Date.now() / 1000),
): Promise<OpenedPair> {
  if (env.v !== 1) throw new OpenError("version");
  if (env.k !== "pair") throw new OpenError("kind");
  const h = header(env.id, env.ts, env.k, env.from);
  const epk = unb64u(env.epk);
  const n = unb64u(env.n);
  const ct = unb64u(env.ct);
  const key = await deriveKey(null, epk, ownKa, ownKa.pub);
  let pt: Uint8Array;
  try {
    pt = await aesGcm("decrypt", key, n, ct, h);
  } catch {
    throw new OpenError("decrypt");
  }
  let cardJson: string, card: OpenedPair["card"], proof: Uint8Array;
  try {
    const body = JSON.parse(dec.decode(pt));
    cardJson = body.card;
    card = JSON.parse(cardJson);
    proof = unb64u(body.proof);
    if (unb64u(card.ks).length !== 65) throw new Error();
  } catch {
    throw new OpenError("encoding");
  }
  const ks = unb64u(card.ks);
  if (env.from !== (await fingerprint(ks))) throw new OpenError("peer");
  const ok = await subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    await importVerifyPub(ks),
    unb64u(env.sig),
    concat(h, epk, n, ct),
  );
  if (!ok) throw new OpenError("signature");
  if (env.ts < now - 86400 || env.ts > now + 300) throw new OpenError("stale");
  const expected = await pairProof(ps, cardJson);
  if (expected.length !== proof.length || !expected.every((b, i) => b === proof[i])) throw new OpenError("proof");
  return { card, cardJson, proof };
}
export { enc, dec };

// ---------- file sessions (SPEC.md "File sessions") ----------

export const SESSION_INFO = enc.encode("teleport/v1/session");
export const DIR_PHONE_TO_MAC = 1;
export const DIR_MAC_TO_PHONE = 2;

export interface Hello {
  t: "hello";
  v: 1;
  from: string;
  epk: string;
  n: string;
  ts: number;
  sig: string;
}
export interface Accept {
  t: "accept";
  epk: string;
  n: string;
  sig: string;
}

/** The bytes the phone signs. */
export function helloTranscript(mailbox: string, h: Omit<Hello, "t" | "v" | "sig">): Uint8Array {
  return enc.encode(`teleport/v1/session|${mailbox}|${h.from}|${h.epk}|${h.n}|${h.ts}`);
}

/** The bytes the Mac signs; its SHA-256 is the HKDF salt. */
export function acceptTranscript(helloT: Uint8Array, a: Omit<Accept, "t" | "sig">): Uint8Array {
  return concat(helloT, enc.encode(`|${a.epk}|${a.n}`));
}

async function ecdsaSign(ks: RawKeyPair, data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await importSignPriv(ks), data));
}

export async function ecdsaVerify(pub: Uint8Array, sig: Uint8Array, data: Uint8Array): Promise<boolean> {
  return subtle.verify({ name: "ECDSA", hash: "SHA-256" }, await importVerifyPub(pub), sig, data);
}

export async function makeHello(phoneKs: RawKeyPair, mailbox: string, eph: RawKeyPair, n: Uint8Array, ts: number): Promise<Hello> {
  const body = { from: await fingerprint(phoneKs.pub), epk: b64u(eph.pub), n: b64u(n), ts };
  const sig = await ecdsaSign(phoneKs, helloTranscript(mailbox, body));
  return { t: "hello", v: 1, ...body, sig: b64u(sig) };
}

export async function makeAccept(macKs: RawKeyPair, helloT: Uint8Array, eph: RawKeyPair, n: Uint8Array): Promise<Accept> {
  const body = { epk: b64u(eph.pub), n: b64u(n) };
  const sig = await ecdsaSign(macKs, acceptTranscript(helloT, body));
  return { t: "accept", ...body, sig: b64u(sig) };
}

/** 64 bytes: phone→Mac key ‖ Mac→phone key. Either side: own ephemeral private, other's ephemeral public. */
export async function sessionKeys(ownEph: RawKeyPair, otherEpk: Uint8Array, acceptT: Uint8Array): Promise<{ p2m: Uint8Array; m2p: Uint8Array }> {
  const ss = await subtle.deriveBits({ name: "ECDH", public: await importEcdhPub(otherEpk) }, await importEcdhPriv(ownEph), 256);
  const salt = new Uint8Array(await subtle.digest("SHA-256", acceptT));
  const ikm = await subtle.importKey("raw", ss, "HKDF", false, ["deriveBits"]);
  const okm = new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info: SESSION_INFO }, ikm, 512));
  return { p2m: okm.slice(0, 32), m2p: okm.slice(32, 64) };
}

/** Nonce for frame `counter` in direction `dir`: dir (4 bytes BE) ‖ counter (8 bytes BE). */
export function frameNonce(dir: number, counter: number): Uint8Array {
  const n = new Uint8Array(12);
  const v = new DataView(n.buffer);
  v.setUint32(0, dir);
  v.setBigUint64(4, BigInt(counter));
  return n;
}

export const sealFrame = (key: Uint8Array, dir: number, counter: number, plaintext: Uint8Array) =>
  aesGcm("encrypt", key, frameNonce(dir, counter), plaintext, new Uint8Array());
export const openFrame = (key: Uint8Array, dir: number, counter: number, frame: Uint8Array) =>
  aesGcm("decrypt", key, frameNonce(dir, counter), frame, new Uint8Array());

/** Frame plaintexts: 0x01 ‖ JSON control, or 0x02 ‖ transfer id (u32 BE) ‖ bytes. */
export function controlPlaintext(msg: object): Uint8Array {
  return concat(new Uint8Array([1]), enc.encode(JSON.stringify(msg)));
}
export function dataPlaintext(id: number, bytes: Uint8Array): Uint8Array {
  const head = new Uint8Array(5);
  head[0] = 2;
  new DataView(head.buffer).setUint32(1, id);
  return concat(head, bytes);
}

/**
 * Mac-side path check (relative to home). Returns the normalised relative path or null.
 * Symlink resolution happens on the Mac against the real file system; this covers the lexical rules.
 */
export function checkPath(path: string, showHidden: boolean): string | null {
  if (path.startsWith("/") || path.includes("\0")) return null;
  const parts = path.split("/").filter((p) => p !== "" && p !== ".");
  if (parts.some((p) => p === "..")) return null;
  if (!showHidden && parts.some((p, i) => p.startsWith(".") || (i === 0 && p === "Library"))) return null;
  return parts.join("/");
}

// ---------- chunked blobs (SPEC.md "Large blobs") ----------

/** Plaintext bytes per chunk for large blobs. */
export const BLOB_CHUNK = 4 * 1024 * 1024;

/** Nonce for chunk i: n[0..4] ‖ (n[4..12] XOR u64be(i)). Unique per chunk under one key. */
export function chunkNonce(n: Uint8Array, i: number): Uint8Array {
  const out = n.slice();
  const v = new DataView(out.buffer, out.byteOffset, out.byteLength);
  v.setBigUint64(4, v.getBigUint64(4) ^ BigInt(i));
  return out;
}

/** AAD for chunk i: "teleport/v1/blob" ‖ u64be(i) ‖ last (1 byte). Binds order and the end. */
export function chunkAad(i: number, last: boolean): Uint8Array {
  const tail = new Uint8Array(9);
  new DataView(tail.buffer).setBigUint64(0, BigInt(i));
  tail[8] = last ? 1 : 0;
  return concat(BLOB_AAD, tail);
}

/** Number of chunks: at least one (an empty file is one empty, final chunk). */
export const chunkCount = (size: number, chunk: number) => Math.max(1, Math.ceil(size / chunk));

export async function sealBlobChunked(bytes: Uint8Array, key: Uint8Array, n: Uint8Array, chunk = BLOB_CHUNK): Promise<Uint8Array> {
  const count = chunkCount(bytes.length, chunk);
  const parts: Uint8Array[] = [];
  for (let i = 0; i < count; i++) {
    const piece = bytes.subarray(i * chunk, Math.min((i + 1) * chunk, bytes.length));
    parts.push(await aesGcm("encrypt", key, chunkNonce(n, i), piece, chunkAad(i, i === count - 1)));
  }
  return concat(...parts);
}

/** Throws unless every chunk authenticates, in order, ending with the final chunk at `size`. */
export async function openBlobChunked(ct: Uint8Array, key: Uint8Array, n: Uint8Array, size: number, chunk: number): Promise<Uint8Array> {
  const count = chunkCount(size, chunk);
  if (ct.length !== size + 16 * count) throw new OpenError("decrypt");
  const parts: Uint8Array[] = [];
  let offset = 0;
  for (let i = 0; i < count; i++) {
    const plain = i === count - 1 ? size - i * chunk : chunk;
    const piece = ct.subarray(offset, offset + plain + 16);
    offset += plain + 16;
    try {
      parts.push(await aesGcm("decrypt", key, chunkNonce(n, i), piece, chunkAad(i, i === count - 1)));
    } catch {
      throw new OpenError("decrypt");
    }
  }
  return concat(...parts);
}
