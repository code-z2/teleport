// Teleport relay: stateless, blind. Routes sealed envelopes to FCM and holds
// encrypted blobs in R2 until the recipient deletes them (1-day lifecycle backstop).
// Never logs request bodies or tokens.

import { type Hint, buildMessages, sendAll, type Recipient, type ServiceAccount } from "./fcm";
import { isToken, parseEnvelope } from "./envelope";

export { MacMailbox } from "./mailbox";

export interface Env {
  BLOBS: R2Bucket;
  MAILBOX: DurableObjectNamespace;
  LIMITER?: RateLimit;
  RELAY_KEY: string;
  FCM_SERVICE_ACCOUNT: string; // JSON of the Firebase service account
}

export const MAX_BLOB_BYTES = 10 * 1024 * 1024;
/** Large (chunked) blobs: 250 MiB of plaintext plus a 16-byte tag per 4 MiB chunk. */
export const MAX_LARGE_BLOB_BYTES = 250 * 1024 * 1024 + 16 * 64;
/** One multipart part; clients send 16 MiB parts, this leaves headroom. */
export const MAX_PART_BYTES = 32 * 1024 * 1024;
const MAX_PARTS = 64;
const BLOB_ID = /^[A-Za-z0-9_-]{22}$/;
const MAILBOX_ID = /^[A-Za-z0-9_-]{11}$/;

/** Forwards to the Mac's mailbox Durable Object, telling it its own id. */
function mailbox(env: Env, id: string, path: string, init: Request | RequestInit): Promise<Response> {
  const stub = env.MAILBOX.get(env.MAILBOX.idFromName(id));
  return stub.fetch(new Request(`https://mailbox${path}?id=${id}`, init));
}

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
  let body: { to?: Partial<Omit<Recipient, "platform">> & { platform?: string; mailbox?: unknown }; env?: unknown; hint?: unknown };
  try {
    body = await req.json();
  } catch {
    return err(400, "invalid json");
  }
  const to = body.to;
  // Computers (Mac, Windows) are reached through their mailbox, not push.
  if (to?.platform === "mac" || to?.platform === "windows") {
    if (typeof to.mailbox !== "string" || !MAILBOX_ID.test(to.mailbox)) return err(400, "invalid to.mailbox");
    const envelope = parseEnvelope(body.env);
    if (typeof envelope === "string") return err(400, envelope);
    return mailbox(env, to.mailbox, "/deliver", { method: "POST", body: JSON.stringify(envelope) });
  }
  if (!to || (to.platform !== "ios" && to.platform !== "android") || !isToken(to.fcm)) return err(400, "invalid to");
  if (to.la !== undefined && (to.platform !== "ios" || !isToken(to.la))) return err(400, "invalid to.la");
  if (body.hint !== undefined && body.hint !== "file" && body.hint !== "image") return err(400, "invalid hint");
  const envelope = parseEnvelope(body.env);
  if (typeof envelope === "string") return err(400, envelope);

  const sa = JSON.parse(env.FCM_SERVICE_ACCOUNT) as ServiceAccount;
  const now = Math.floor(Date.now() / 1000);
  const [primary, liveActivity] = await sendAll(sa, buildMessages(to as Recipient, envelope, now, body.hint as Hint | undefined), now);
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

/**
 * Large blobs: an R2 multipart upload, because a Worker can't take a 250 MB request body.
 *   POST   /v1/blob/upload                          → { id, upload }
 *   PUT    /v1/blob/upload/:id/:upload/:part        → { etag }        (part 1…64, ≤ 32 MiB)
 *   POST   /v1/blob/upload/:id/:upload/complete     { parts:[{part,etag}] } → { ok }
 *   DELETE /v1/blob/upload/:id/:upload              → 204
 */
async function handleUpload(req: Request, env: Env, url: URL): Promise<Response> {
  if (url.pathname === "/v1/blob/upload") {
    if (req.method !== "POST") return err(405, "method not allowed");
    const id = newBlobId();
    const upload = await env.BLOBS.createMultipartUpload(id, { httpMetadata: { contentType: "application/octet-stream" } });
    return json({ id, upload: upload.uploadId }, 201);
  }
  const m = url.pathname.match(/^\/v1\/blob\/upload\/([^/]+)\/([^/]+)(?:\/([^/]+))?$/);
  if (!m) return err(404, "not found");
  const [, id, rawUpload, step] = m;
  if (!BLOB_ID.test(id)) return err(404, "not found");
  const uploadId = decodeURIComponent(rawUpload);
  if (uploadId.length > 1024) return err(400, "invalid upload");
  const upload = env.BLOBS.resumeMultipartUpload(id, uploadId);

  if (step === undefined) {
    if (req.method !== "DELETE") return err(405, "method not allowed");
    try { await upload.abort(); } catch { /* already gone */ }
    return new Response(null, { status: 204 });
  }
  if (step === "complete") {
    if (req.method !== "POST") return err(405, "method not allowed");
    let body: { parts?: { part?: unknown; etag?: unknown }[] };
    try { body = await req.json(); } catch { return err(400, "invalid json"); }
    const parts = body.parts;
    if (!Array.isArray(parts) || parts.length === 0 || parts.length > MAX_PARTS) return err(400, "invalid parts");
    const list: R2UploadedPart[] = [];
    for (const p of parts) {
      if (typeof p.part !== "number" || !Number.isInteger(p.part) || typeof p.etag !== "string") return err(400, "invalid parts");
      list.push({ partNumber: p.part, etag: p.etag });
    }
    let obj: R2Object;
    try { obj = await upload.complete(list); } catch { return err(400, "upload failed"); }
    if (obj.size > MAX_LARGE_BLOB_BYTES) {
      await env.BLOBS.delete(id);
      return err(413, "blob too large");
    }
    return json({ ok: true });
  }
  // A part.
  if (req.method !== "PUT") return err(405, "method not allowed");
  const part = Number(step);
  if (!Number.isInteger(part) || part < 1 || part > MAX_PARTS) return err(400, "invalid part");
  const len = Number(req.headers.get("content-length") ?? NaN);
  if (!Number.isFinite(len) || len <= 0) return err(411, "content-length required");
  if (len > MAX_PART_BYTES) return err(413, "part too large");
  const bytes = await req.arrayBuffer();
  if (bytes.byteLength > MAX_PART_BYTES) return err(413, "part too large");
  try {
    const uploaded = await upload.uploadPart(part, bytes);
    return json({ etag: uploaded.etag });
  } catch {
    return err(400, "unknown upload");
  }
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
    const mb = url.pathname.match(/^\/v1\/mailbox\/([^/]+)\/(connect|status|session)$/);
    if (mb) {
      const [, id, action] = mb;
      if (!MAILBOX_ID.test(id)) return err(404, "not found");
      if (action === "status" && req.method !== "GET") return err(405, "method not allowed");
      return mailbox(env, id, `/${action}`, req);
    }
    if (url.pathname === "/v1/blob/upload" || url.pathname.startsWith("/v1/blob/upload/")) return handleUpload(req, env, url);
    const m = url.pathname.match(/^\/v1\/blob\/([^/]+)$/);
    if (m) return handleBlob(req, env, m[1]);
    return err(404, "not found");
  },
} satisfies ExportedHandler<Env>;
