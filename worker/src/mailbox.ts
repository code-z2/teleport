// MacMailbox: one Durable Object per Mac, named by its id (fp of its signing key).
// Holds the Mac's live WebSocket and phone sessions, and relays bytes between them.
// Blind: it never sees plaintext, and stores nothing apart from the attachments on
// the open WebSocket connections. See protocol/SPEC.md "Mac mailbox".

import { DurableObject } from "cloudflare:workers";
import type { Envelope } from "./envelope";

export interface MailboxEnv {
  RELAY_KEY: string;
}

const AUTH_TIMEOUT_MS = 30_000;
const MAX_SESSIONS = 8;
const MAX_MESSAGE_BYTES = 1024 * 1024;
const SID_BYTES = 16;

type Attachment =
  | { role: "mac"; authed: false; id: string; nonce: string; opened: number }
  | { role: "mac"; authed: true; since: number }
  | { role: "phone"; sid: string };

const enc = new TextEncoder();

export const b64u = (bytes: Uint8Array): string => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

export const unb64u = (s: string): Uint8Array => {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};

export async function fingerprint(pub: Uint8Array): Promise<string> {
  return b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", pub)).slice(0, 8));
}

export function challengeMessage(id: string, nonce: string): Uint8Array {
  return enc.encode(`teleport/v1/mailbox|${id}|${nonce}`);
}

async function verifyAuth(id: string, nonce: string, ksB64: unknown, sigB64: unknown): Promise<boolean> {
  try {
    if (typeof ksB64 !== "string" || typeof sigB64 !== "string") return false;
    const ks = unb64u(ksB64);
    const sig = unb64u(sigB64);
    if (ks.length !== 65 || sig.length !== 64 || (await fingerprint(ks)) !== id) return false;
    const key = await crypto.subtle.importKey("raw", ks, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, challengeMessage(id, nonce));
  } catch {
    return false;
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export class MacMailbox extends DurableObject<MailboxEnv> {
  constructor(ctx: DurableObjectState, env: MailboxEnv) {
    super(ctx, env);
    // Keep-alives are answered by the runtime without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  // ---------- helpers ----------

  private attachment(ws: WebSocket): Attachment | null {
    return (ws.deserializeAttachment() as Attachment | null) ?? null;
  }

  /** The authenticated Mac connection, if any (ignoring `except`, e.g. one that's closing). */
  private mac(except?: WebSocket): WebSocket | null {
    for (const ws of this.ctx.getWebSockets("mac")) {
      if (ws === except) continue;
      // A socket that's closing (or closed under us) still shows up here for a while.
      if (ws.readyState !== WebSocket.OPEN) continue;
      const a = this.attachment(ws);
      if (a?.role === "mac" && a.authed) return ws;
    }
    return null;
  }

  private sessions(): WebSocket[] {
    return this.ctx.getWebSockets("phone");
  }

  private session(sid: string): WebSocket | null {
    return this.ctx.getWebSockets(`sid:${sid}`)[0] ?? null;
  }

  private static close(ws: WebSocket, code: number, reason: string) {
    try {
      ws.close(code, reason);
    } catch {
      // already closed
    }
  }

  // ---------- HTTP entry points (routed here by the Worker) ----------

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const id = url.searchParams.get("id") ?? "";
    switch (url.pathname) {
      case "/connect":
        return this.acceptMac(req, id);
      case "/status": {
        const mac = this.mac();
        const a = mac ? this.attachment(mac) : null;
        return json({ online: mac !== null, since: a?.role === "mac" && a.authed ? a.since : null });
      }
      case "/deliver":
        return this.deliver((await req.json()) as Envelope);
      case "/session":
        return this.openSession(req);
      default:
        return json({ ok: false, error: "not found" }, 404);
    }
  }

  private acceptMac(req: Request, id: string): Response {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return json({ ok: false, error: "expected websocket" }, 426);
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["mac"]);
    const nonce = b64u(crypto.getRandomValues(new Uint8Array(32)));
    server.serializeAttachment({ role: "mac", authed: false, id, nonce, opened: Date.now() } satisfies Attachment);
    server.send(JSON.stringify({ t: "challenge", nonce }));
    // Sweep connections that never authenticate.
    void this.ctx.storage.setAlarm(Date.now() + AUTH_TIMEOUT_MS + 1_000);
    return new Response(null, { status: 101, webSocket: client });
  }

  private deliver(env: Envelope): Response {
    const mac = this.mac();
    if (!mac) return json({ ok: false, error: "offline" }, 503);
    try {
      mac.send(JSON.stringify({ t: "env", env }));
    } catch {
      // The connection died between the check and the send: it's gone, and so is the Mac.
      MacMailbox.close(mac, 1011, "dead");
      return json({ ok: false, error: "offline" }, 503);
    }
    return json({ ok: true });
  }

  private openSession(req: Request): Response {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return json({ ok: false, error: "expected websocket" }, 426);
    const mac = this.mac();
    if (!mac) return json({ ok: false, error: "offline" }, 503);
    if (this.sessions().length >= MAX_SESSIONS) return json({ ok: false, error: "too many sessions" }, 429);
    const sid = b64u(crypto.getRandomValues(new Uint8Array(SID_BYTES)));
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["phone", `sid:${sid}`]);
    server.serializeAttachment({ role: "phone", sid } satisfies Attachment);
    mac.send(JSON.stringify({ t: "open", sid }));
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---------- WebSocket events (hibernation API) ----------

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const a = this.attachment(ws);
    if (!a) return MacMailbox.close(ws, 4400, "unknown connection");
    const size = typeof message === "string" ? message.length : message.byteLength;
    if (size > MAX_MESSAGE_BYTES) return MacMailbox.close(ws, 1009, "message too large");

    if (a.role === "phone") {
      if (typeof message === "string") return MacMailbox.close(ws, 4400, "binary only");
      const mac = this.mac();
      if (!mac) return MacMailbox.close(ws, 4410, "mac gone");
      const framed = new Uint8Array(SID_BYTES + message.byteLength);
      framed.set(unb64u(a.sid), 0);
      framed.set(new Uint8Array(message), SID_BYTES);
      mac.send(framed);
      return;
    }

    // Mac, not yet authenticated: only {"t":"auth"} is accepted.
    if (!a.authed) {
      if (typeof message !== "string") return MacMailbox.close(ws, 4401, "auth required");
      let msg: { t?: string; ks?: unknown; sig?: unknown };
      try {
        msg = JSON.parse(message);
      } catch {
        return MacMailbox.close(ws, 4401, "auth required");
      }
      if (msg.t !== "auth" || !(await verifyAuth(a.id, a.nonce, msg.ks, msg.sig))) {
        return MacMailbox.close(ws, 4401, "auth failed");
      }
      // A newer authenticated connection replaces the older one.
      for (const other of this.ctx.getWebSockets("mac")) {
        if (other !== ws) MacMailbox.close(other, 4000, "replaced");
      }
      ws.serializeAttachment({ role: "mac", authed: true, since: Math.floor(Date.now() / 1000) } satisfies Attachment);
      ws.send(JSON.stringify({ t: "ready" }));
      return;
    }

    // Authenticated Mac.
    if (typeof message === "string") {
      let msg: { t?: string; sid?: string };
      try {
        msg = JSON.parse(message);
      } catch {
        return;
      }
      if (msg.t === "close" && typeof msg.sid === "string") {
        const phone = this.session(msg.sid);
        if (phone) MacMailbox.close(phone, 1000, "closed by mac");
      }
      return;
    }
    if (message.byteLength < SID_BYTES) return;
    const bytes = new Uint8Array(message);
    const phone = this.session(b64u(bytes.slice(0, SID_BYTES)));
    phone?.send(bytes.slice(SID_BYTES));
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    const a = this.attachment(ws);
    MacMailbox.close(ws, code === 1005 ? 1000 : code, reason);
    if (a?.role === "phone") {
      this.mac()?.send(JSON.stringify({ t: "close", sid: a.sid }));
    } else if (a?.role === "mac" && a.authed && this.mac(ws) === null) {
      // The Mac went away (and wasn't replaced): end every session.
      for (const phone of this.sessions()) MacMailbox.close(phone, 4410, "mac gone");
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws, 1011, "error");
  }

  /** Close Mac connections that never authenticated. */
  async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets("mac")) {
      const a = this.attachment(ws);
      if (a?.role === "mac" && !a.authed && now - a.opened >= AUTH_TIMEOUT_MS) MacMailbox.close(ws, 4408, "auth timeout");
    }
  }
}
