// Teleport protocol v1 — TypeScript reference implementation (WebCrypto).
// Used to generate and check protocol/vectors.json. See protocol/SPEC.md.

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();

export type Kind = "text" | "blob" | "peer";
export const KINDS: readonly Kind[] = ["text", "blob", "peer"];
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

export type OpenErrorCode = "version" | "kind" | "peer" | "signature" | "stale" | "decrypt";

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
export { enc, dec };
