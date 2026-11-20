// Mac mailbox (SPEC.md "Mac mailbox"), tested against the real Durable Object in the
// Workers runtime. The test plays both the Mac and a phone.
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { b64u, challengeMessage, fingerprint } from "../src/mailbox";

const KEY = "k".repeat(40);
const auth = { Authorization: `Bearer ${KEY}` };
const worker = (exports as unknown as { default: Fetcher }).default;

async function macKeys() {
  const kp = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const ks = new Uint8Array((await crypto.subtle.exportKey("raw", kp.publicKey)) as ArrayBuffer);
  return { kp, ks, id: await fingerprint(ks) };
}

/** A WebSocket with an awaitable message queue. */
class Socket {
  private queue: (string | ArrayBuffer)[] = [];
  private waiters: ((m: string | ArrayBuffer) => void)[] = [];
  closed: Promise<{ code: number; reason: string }>;

  constructor(readonly ws: WebSocket) {
    ws.accept();
    ws.addEventListener("message", (e) => {
      const w = this.waiters.shift();
      if (w) w(e.data as string | ArrayBuffer);
      else this.queue.push(e.data as string | ArrayBuffer);
    });
    this.closed = new Promise((resolve) => ws.addEventListener("close", (e) => resolve({ code: e.code, reason: e.reason })));
  }

  next(): Promise<string | ArrayBuffer> {
    const m = this.queue.shift();
    return m !== undefined ? Promise.resolve(m) : new Promise((r) => this.waiters.push(r));
  }

  async json(): Promise<Record<string, unknown>> {
    const m = await this.next();
    if (typeof m !== "string") throw new Error("expected text");
    return JSON.parse(m);
  }

  async bytes(): Promise<Uint8Array> {
    const m: unknown = await this.next();
    if (typeof m === "string") throw new Error("expected binary");
    // Binary messages may arrive as a Blob, an ArrayBuffer, or a view.
    if (m instanceof Blob) return new Uint8Array(await m.arrayBuffer());
    if (ArrayBuffer.isView(m)) return new Uint8Array(m.buffer, m.byteOffset, m.byteLength);
    return new Uint8Array(m as ArrayBuffer);
  }
}

async function open(path: string): Promise<Socket> {
  const res = await worker.fetch(`https://relay.test${path}`, { headers: { Upgrade: "websocket", ...auth } });
  expect(res.status).toBe(101);
  return new Socket(res.webSocket!);
}

/** Connects as the Mac and completes the challenge with `signer` (defaults to the owner). */
async function connectMac(mac: Awaited<ReturnType<typeof macKeys>>, signer = mac) {
  const s = await open(`/v1/mailbox/${mac.id}/connect`);
  const challenge = await s.json();
  expect(challenge.t).toBe("challenge");
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer.kp.privateKey, challengeMessage(mac.id, challenge.nonce as string)),
  );
  s.ws.send(JSON.stringify({ t: "auth", ks: b64u(signer.ks), sig: b64u(sig) }));
  return s;
}

const status = async (id: string) =>
  (await (await worker.fetch(`https://relay.test/v1/mailbox/${id}/status`, { headers: auth })).json()) as {
    online: boolean;
    since: number | null;
  };

// A shape-valid envelope (the relay never decrypts).
const ENV = {
  v: 1, id: "A".repeat(22), ts: 1_790_000_000, k: "text", from: "B".repeat(11),
  epk: "C".repeat(87), n: "D".repeat(16), ct: "E".repeat(40), sig: "F".repeat(86),
};

describe("mac connection", () => {
  it("is offline until the Mac authenticates", async () => {
    const mac = await macKeys();
    expect(await status(mac.id)).toEqual({ online: false, since: null });
    const s = await connectMac(mac);
    expect(await s.json()).toEqual({ t: "ready" });
    const st = await status(mac.id);
    expect(st.online).toBe(true);
    expect(typeof st.since).toBe("number");
  });

  it("rejects a key that doesn't own the mailbox", async () => {
    const mac = await macKeys();
    const intruder = await macKeys();
    const s = await connectMac(mac, intruder);
    expect((await s.closed).code).toBe(4401);
    expect((await status(mac.id)).online).toBe(false);
  });

  it("rejects a bad signature", async () => {
    const mac = await macKeys();
    const s = await open(`/v1/mailbox/${mac.id}/connect`);
    await s.json();
    s.ws.send(JSON.stringify({ t: "auth", ks: b64u(mac.ks), sig: b64u(new Uint8Array(64)) }));
    expect((await s.closed).code).toBe(4401);
  });

  it("a newer connection replaces the older one", async () => {
    const mac = await macKeys();
    const first = await connectMac(mac);
    await first.json();
    const second = await connectMac(mac);
    expect(await second.json()).toEqual({ t: "ready" });
    expect((await first.closed).code).toBe(4000);
    expect((await status(mac.id)).online).toBe(true);
  });

  it("requires the relay key", async () => {
    const mac = await macKeys();
    const res = await worker.fetch(`https://relay.test/v1/mailbox/${mac.id}/status`);
    expect(res.status).toBe(401);
  });
});

describe("delivering envelopes", () => {
  const send = (id: string) =>
    worker.fetch("https://relay.test/v1/send", {
      method: "POST",
      headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({ to: { platform: "mac", mailbox: id }, env: ENV }),
    });

  it("returns 503 offline when the Mac isn't connected", async () => {
    const mac = await macKeys();
    const res = await send(mac.id);
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ ok: false, error: "offline" });
  });

  it("hands the envelope to the connected Mac", async () => {
    const mac = await macKeys();
    const s = await connectMac(mac);
    await s.json();
    const res = await send(mac.id);
    expect(res.status).toBe(200);
    expect(await s.json()).toEqual({ t: "env", env: ENV });
  });
});

describe("sessions", () => {
  it("returns 503 when the Mac is offline", async () => {
    const mac = await macKeys();
    const res = await worker.fetch(`https://relay.test/v1/mailbox/${mac.id}/session`, { headers: { Upgrade: "websocket", ...auth } });
    expect(res.status).toBe(503);
  });

  it("relays bytes both ways, tagged with the session id on the Mac side", async () => {
    const mac = await macKeys();
    const m = await connectMac(mac);
    await m.json();

    const phone = await open(`/v1/mailbox/${mac.id}/session`);
    const opened = await m.json();
    expect(opened.t).toBe("open");
    const sid = opened.sid as string;

    phone.ws.send(new Uint8Array([1, 2, 3]));
    const atMac = await m.bytes();
    expect(b64u(atMac.slice(0, 16))).toBe(sid);
    expect([...atMac.slice(16)]).toEqual([1, 2, 3]);

    const reply = new Uint8Array(16 + 2);
    reply.set(atMac.slice(0, 16));
    reply.set([9, 8], 16);
    m.ws.send(reply);
    expect([...(await phone.bytes())]).toEqual([9, 8]);

    // The Mac ends the session.
    m.ws.send(JSON.stringify({ t: "close", sid }));
    expect((await phone.closed).code).toBe(1000);
  });

  it("tells the Mac when the phone hangs up", async () => {
    const mac = await macKeys();
    const m = await connectMac(mac);
    await m.json();
    const phone = await open(`/v1/mailbox/${mac.id}/session`);
    const { sid } = await m.json();
    phone.ws.close(1000, "done");
    expect(await m.json()).toEqual({ t: "close", sid });
  });

  it("closes sessions when the Mac disconnects", async () => {
    const mac = await macKeys();
    const m = await connectMac(mac);
    await m.json();
    const phone = await open(`/v1/mailbox/${mac.id}/session`);
    await m.json();
    m.ws.close(1000, "sleep");
    expect((await phone.closed).code).toBe(4410);
  });

  it("only accepts binary from the phone", async () => {
    const mac = await macKeys();
    const m = await connectMac(mac);
    await m.json();
    const phone = await open(`/v1/mailbox/${mac.id}/session`);
    await m.json();
    phone.ws.send("hello");
    expect((await phone.closed).code).toBe(4400);
  });
});
