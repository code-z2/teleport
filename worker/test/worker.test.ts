import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import worker, { type Env } from "../src/index";
import { parseEnvelope } from "../src/envelope";
import { buildMessages } from "../src/fcm";

const vectors = JSON.parse(readFileSync(new URL("../../protocol/vectors.json", import.meta.url), "utf8"));
const ENV = vectors.cases[0].env;
const KEY = "k".repeat(40);

class FakeR2 {
  store = new Map<string, Uint8Array>();
  async put(k: string, v: ArrayBuffer) {
    this.store.set(k, new Uint8Array(v));
  }
  async get(k: string) {
    const v = this.store.get(k);
    return v ? { body: new Blob([v]).stream(), size: v.length } : null;
  }
  async delete(k: string) {
    this.store.delete(k);
  }
}

async function serviceAccount(): Promise<string> {
  const kp = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const der = Buffer.from((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  return JSON.stringify({ project_id: "proj", client_email: "sa@proj.iam.gserviceaccount.com", private_key: pem });
}

const makeEnv = async (): Promise<Env> => ({
  BLOBS: new FakeR2() as unknown as R2Bucket,
  RELAY_KEY: KEY,
  FCM_SERVICE_ACCOUNT: await serviceAccount(),
});

const req = (path: string, init: RequestInit = {}, key = KEY) =>
  new Request(`https://relay.test${path}`, {
    ...init,
    headers: { authorization: `Bearer ${key}`, ...(init.headers as Record<string, string>) },
  });

afterEach(() => vi.unstubAllGlobals());

describe("envelope validation", () => {
  it("accepts every protocol vector", () => {
    for (const c of vectors.cases) expect(parseEnvelope(c.env)).toEqual(c.env);
  });
  it("rejects bad shapes", () => {
    expect(parseEnvelope({ ...ENV, v: 2 })).toBe("invalid env.v");
    expect(parseEnvelope({ ...ENV, epk: "abc" })).toBe("invalid env.epk");
    expect(parseEnvelope({ ...ENV, ct: "a".repeat(3000) })).toBe("env too large");
    expect(parseEnvelope({ ...ENV, extra: 1 })).toBe("unexpected env.extra");
    expect(parseEnvelope(null)).toBe("env must be an object");
  });
});

describe("buildMessages", () => {
  it("android: one high-priority data message", () => {
    const [m, ...rest] = buildMessages({ platform: "android", fcm: "t" }, ENV, 1000) as any[];
    expect(rest).toHaveLength(0);
    expect(m.android).toEqual({ priority: "HIGH", ttl: "300s" });
    expect(JSON.parse(m.data.env)).toEqual(ENV);
  });
  it("ios: alert with mutable-content, plus Live Activity start when la is set", () => {
    const [alert, la] = buildMessages({ platform: "ios", fcm: "t", la: "p2s" }, ENV, 1000) as any[];
    expect(alert.apns.payload.aps["mutable-content"]).toBe(1);
    expect(alert.apns.payload.aps.category).toBe("CLIP");
    expect(JSON.parse(alert.apns.payload.env)).toEqual(ENV);
    expect(la.apns.live_activity_token).toBe("p2s");
    expect(la.apns.payload.aps.event).toBe("start");
    expect(la.apns.payload.aps["attributes-type"]).toBe("ClipActivityAttributes");
    expect(JSON.parse(la.apns.payload.aps["content-state"].env)).toEqual(ENV);
    expect(la.apns.payload.aps["dismissal-date"]).toBe(1300);
  });
  it("ios: no Live Activity for peer updates", () => {
    expect(buildMessages({ platform: "ios", fcm: "t", la: "p2s" }, { ...ENV, k: "peer" }, 0)).toHaveLength(1);
  });
});

describe("auth", () => {
  it("rejects a missing or wrong key", async () => {
    const env = await makeEnv();
    expect((await worker.fetch(req("/v1/send", { method: "POST" }, "wrong"), env)).status).toBe(401);
    expect((await worker.fetch(new Request("https://relay.test/v1/send"), env)).status).toBe(401);
  });
  it("rejects when RELAY_KEY is too short", async () => {
    const env = { ...(await makeEnv()), RELAY_KEY: "short" };
    expect((await worker.fetch(req("/v1/send", {}, "short"), env)).status).toBe(401);
  });
});

describe("blobs", () => {
  it("put → get → delete", async () => {
    const env = await makeEnv();
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const put = await worker.fetch(req("/v1/blob", { method: "PUT", body: bytes, headers: { "content-length": "4" } }), env);
    expect(put.status).toBe(201);
    const { id } = (await put.json()) as { id: string };
    expect(id).toMatch(/^[A-Za-z0-9_-]{22}$/);

    const get = await worker.fetch(req(`/v1/blob/${id}`), env);
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(bytes);

    expect((await worker.fetch(req(`/v1/blob/${id}`, { method: "DELETE" }), env)).status).toBe(204);
    expect((await worker.fetch(req(`/v1/blob/${id}`), env)).status).toBe(404);
  });
  it("rejects oversized blobs by content-length", async () => {
    const env = await makeEnv();
    const r = await worker.fetch(
      req("/v1/blob", { method: "PUT", body: "x", headers: { "content-length": String(11 * 1024 * 1024) } }),
      env,
    );
    expect(r.status).toBe(413);
  });
});

describe("send", () => {
  it("mints an OAuth token and posts to FCM", async () => {
    const env = await makeEnv();
    const calls: { url: string; body: string }[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      calls.push({ url, body: String(init.body) });
      if (url.includes("oauth2")) return Response.json({ access_token: "at", expires_in: 3600 });
      return Response.json({ name: "projects/proj/messages/1" });
    });
    const r = await worker.fetch(
      req("/v1/send", { method: "POST", body: JSON.stringify({ to: { platform: "android", fcm: "tok" }, env: ENV }) }),
      env,
    );
    expect(r.status).toBe(200);
    expect(calls.map((c) => new URL(c.url).hostname)).toContain("fcm.googleapis.com");
    const fcmCall = calls.find((c) => c.url.includes("fcm"))!;
    expect(fcmCall.url).toContain("/projects/proj/messages:send");
    expect(JSON.parse(fcmCall.body).message.token).toBe("tok");
  });
  it("maps UNREGISTERED to 410", async () => {
    const env = await makeEnv();
    vi.stubGlobal("fetch", async (url: string) =>
      url.includes("oauth2")
        ? Response.json({ access_token: "at", expires_in: 3600 })
        : Response.json({ error: { status: "UNREGISTERED" } }, { status: 404 }),
    );
    const r = await worker.fetch(
      req("/v1/send", { method: "POST", body: JSON.stringify({ to: { platform: "ios", fcm: "tok" }, env: ENV }) }),
      env,
    );
    expect(r.status).toBe(410);
  });
  it("validates input", async () => {
    const env = await makeEnv();
    const bad = await worker.fetch(
      req("/v1/send", { method: "POST", body: JSON.stringify({ to: { platform: "android", fcm: "t", la: "x" }, env: ENV }) }),
      env,
    );
    expect(bad.status).toBe(400);
  });
});
