// Teleport relay: stateless, blind. Routes sealed envelopes to FCM and holds
// encrypted blobs in R2 until the recipient deletes them (1-day lifecycle backstop).
// Never logs request bodies or tokens.

import { buildMessages, sendAll, type Recipient, type ServiceAccount } from "./fcm";
import { isToken, parseEnvelope } from "./envelope";

export interface Env {
  BLOBS: R2Bucket;
  LIMITER?: RateLimit;
  RELAY_KEY: string;
  FCM_SERVICE_ACCOUNT: string; // JSON of the Firebase service account
}

export const MAX_BLOB_BYTES = 10 * 1024 * 1024;
const BLOB_ID = /^[A-Za-z0-9_-]{22}$/;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const err = (status: number, error: string) => json({ ok: false, error }, status);

function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export function authorized(req: Request, env: Env): boolean {
  const h = req.headers.get("authorization") ?? "";
  return env.RELAY_KEY.length >= 32 && h.startsWith("Bearer ") && constantTimeEqual(h.slice(7), env.RELAY_KEY);
}

function newBlobId(): string {
  const b = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function handleSend(req: Request, env: Env): Promise<Response> {
  let body: { to?: Partial<Recipient>; env?: unknown };
  try {
    body = await req.json();
  } catch {
    return err(400, "invalid json");
  }
  const to = body.to;
  if (!to || (to.platform !== "ios" && to.platform !== "android") || !isToken(to.fcm)) return err(400, "invalid to");
  if (to.la !== undefined && (to.platform !== "ios" || !isToken(to.la))) return err(400, "invalid to.la");
  const envelope = parseEnvelope(body.env);
  if (typeof envelope === "string") return err(400, envelope);

  const sa = JSON.parse(env.FCM_SERVICE_ACCOUNT) as ServiceAccount;
  const now = Math.floor(Date.now() / 1000);
  const results = await sendAll(sa, buildMessages(to as Recipient, envelope, now), now);
  const [primary, liveActivity] = results;

  if (!primary.ok) {
    // UNREGISTERED / NOT_FOUND → the peer's token is dead; client should re-pair or await a peer update.
    const gone = primary.error === "UNREGISTERED" || primary.status === 404;
    return json({ ok: false, error: primary.error }, gone ? 410 : 502);
  }
  return json({ ok: true, liveActivity: liveActivity ? liveActivity.ok : undefined });
}

async function handleBlob(req: Request, env: Env, id: string | null): Promise<Response> {
  if (req.method === "PUT" && id === null) {
    const len = Number(req.headers.get("content-length") ?? NaN);
    if (!Number.isFinite(len) || len <= 0) return err(411, "content-length required");
    if (len > MAX_BLOB_BYTES) return err(413, "blob too large");
    const bytes = await req.arrayBuffer();
    if (bytes.byteLength > MAX_BLOB_BYTES) return err(413, "blob too large");
    const newId = newBlobId();
    await env.BLOBS.put(newId, bytes, { httpMetadata: { contentType: "application/octet-stream" } });
    return json({ id: newId }, 201);
  }
  if (id === null || !BLOB_ID.test(id)) return err(404, "not found");
  if (req.method === "GET") {
    const obj = await env.BLOBS.get(id);
    if (!obj) return err(404, "not found");
    return new Response(obj.body, {
      headers: { "content-type": "application/octet-stream", "content-length": String(obj.size) },
    });
  }
  if (req.method === "DELETE") {
    await env.BLOBS.delete(id);
    return new Response(null, { status: 204 });
  }
  return err(405, "method not allowed");
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (!authorized(req, env)) return err(401, "unauthorized");

    if (env.LIMITER) {
      const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
      const { success } = await env.LIMITER.limit({ key: ip });
      if (!success) return err(429, "rate limited");
    }

    if (url.pathname === "/v1/send") {
      return req.method === "POST" ? handleSend(req, env) : err(405, "method not allowed");
    }
    if (url.pathname === "/v1/blob") return handleBlob(req, env, null);
    const m = url.pathname.match(/^\/v1\/blob\/([^/]+)$/);
    if (m) return handleBlob(req, env, m[1]);
    return err(404, "not found");
  },
} satisfies ExportedHandler<Env>;
