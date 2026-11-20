// Shape validation only. The relay is blind: it never decrypts or verifies signatures.
// See protocol/SPEC.md.

export interface Envelope {
  v: 1;
  id: string;
  ts: number;
  k: "text" | "blob" | "peer" | "pair" | "pair-ok" | "pair-no";
  from: string;
  epk: string;
  n: string;
  ct: string;
  sig: string;
}

export const MAX_ENVELOPE_BYTES = 3000;
export const KINDS: readonly Envelope["k"][] = ["text", "blob", "peer", "pair", "pair-ok", "pair-no"];

const b64u = (len?: number) => (s: unknown) =>
  typeof s === "string" && /^[A-Za-z0-9_-]*$/.test(s) && (len === undefined || s.length === len);

// base64url lengths (no padding): 16B→22, 8B→11, 65B→87, 12B→16, 64B→86
const checks: Record<keyof Envelope, (x: unknown) => boolean> = {
  v: (x) => x === 1,
  id: b64u(22),
  ts: (x) => Number.isInteger(x) && (x as number) > 0,
  k: (x) => typeof x === "string" && KINDS.includes(x as Envelope["k"]),
  from: b64u(11),
  epk: b64u(87),
  n: b64u(16),
  ct: (x) => b64u()(x) && (x as string).length >= 22, // ≥ 16-byte GCM tag
  sig: b64u(86),
};

export function parseEnvelope(x: unknown): Envelope | string {
  if (typeof x !== "object" || x === null || Array.isArray(x)) return "env must be an object";
  const o = x as Record<string, unknown>;
  for (const [key, ok] of Object.entries(checks)) {
    if (!ok(o[key])) return `invalid env.${key}`;
  }
  const extra = Object.keys(o).filter((k) => !(k in checks));
  if (extra.length) return `unexpected env.${extra[0]}`;
  const env = o as unknown as Envelope;
  if (new TextEncoder().encode(JSON.stringify(env)).length > MAX_ENVELOPE_BYTES) return "env too large";
  return env;
}

export function isToken(x: unknown): x is string {
  return typeof x === "string" && x.length > 0 && x.length <= 4096 && /^[\x21-\x7e]+$/.test(x);
}
