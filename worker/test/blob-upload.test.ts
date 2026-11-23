// Large blobs (SPEC.md "Large blobs"): R2 multipart uploads through the relay, in the
// real Workers runtime with Miniflare's R2.
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const auth = { Authorization: `Bearer ${"k".repeat(40)}` };
const worker = (exports as unknown as { default: Fetcher }).default;
const call = (method: string, path: string, body?: BodyInit, headers: Record<string, string> = {}) =>
  worker.fetch(`https://relay.test${path}`, { method, body, headers: { ...auth, ...headers } });

const MiB = 1024 * 1024;

describe("multipart blob upload", () => {
  it("uploads in parts, streams back, and deletes", async () => {
    const start = await call("POST", "/v1/blob/upload");
    expect(start.status).toBe(201);
    const { id, upload } = (await start.json()) as { id: string; upload: string };

    // R2: every part but the last must be the same size, at least 5 MiB.
    const p1 = new Uint8Array(5 * MiB).fill(1);
    const p2 = new Uint8Array(1234).fill(2);
    const base = `/v1/blob/upload/${id}/${encodeURIComponent(upload)}`;
    const r1 = await call("PUT", `${base}/1`, p1, { "content-length": String(p1.length) });
    const r2 = await call("PUT", `${base}/2`, p2, { "content-length": String(p2.length) });
    expect(r1.status).toBe(200);
    const e1 = ((await r1.json()) as { etag: string }).etag;
    const e2 = ((await r2.json()) as { etag: string }).etag;

    const done = await call("POST", `${base}/complete`, JSON.stringify({ parts: [{ part: 1, etag: e1 }, { part: 2, etag: e2 }] }));
    expect(done.status).toBe(200);

    const got = await call("GET", `/v1/blob/${id}`);
    expect(got.status).toBe(200);
    const bytes = new Uint8Array(await got.arrayBuffer());
    expect(bytes.length).toBe(p1.length + p2.length);
    expect(bytes[0]).toBe(1);
    expect(bytes[bytes.length - 1]).toBe(2);

    expect((await call("DELETE", `/v1/blob/${id}`)).status).toBe(204);
    expect((await call("GET", `/v1/blob/${id}`)).status).toBe(404);
  });

  it("rejects bad parts and unknown uploads", async () => {
    const { id, upload } = (await (await call("POST", "/v1/blob/upload")).json()) as { id: string; upload: string };
    const base = `/v1/blob/upload/${id}/${encodeURIComponent(upload)}`;
    expect((await call("PUT", `${base}/0`, "x", { "content-length": "1" })).status).toBe(400);
    expect((await call("PUT", `${base}/65`, "x", { "content-length": "1" })).status).toBe(400);
    expect((await call("PUT", `${base}/1`, "x", { "content-length": String(33 * MiB) })).status).toBe(413);
    expect((await call("POST", `${base}/complete`, JSON.stringify({ parts: [] }))).status).toBe(400);
    expect((await call("DELETE", base)).status).toBe(204);
    expect((await call("PUT", "/v1/blob/upload/not-an-id/x/1", "x", { "content-length": "1" })).status).toBe(404);
  });

  it("needs the relay key", async () => {
    const res = await worker.fetch("https://relay.test/v1/blob/upload", { method: "POST" });
    expect(res.status).toBe(401);
  });
});
