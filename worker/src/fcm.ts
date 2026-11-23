// FCM HTTP v1: OAuth token minting (service-account JWT, RS256 via WebCrypto)
// and message building for Android data messages, iOS alerts and iOS Live Activities.

import type { Envelope } from "./envelope";

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string; // PKCS#8 PEM
}

export interface Recipient {
  platform: "ios" | "android";
  fcm: string;
  la?: string; // iOS Live Activity push-to-start token
}

const TTL_SECONDS = 300;

// Generic text only; the Notification Service Extension replaces it after decrypting.
const ALERT_BODY: Record<Envelope["k"], string> = {
  text: "New clip",
  blob: "New clip",
  peer: "Device updated",
  pair: "Pairing request",
  "pair-ok": "Paired",
  "pair-no": "Pairing declined",
};

// ---------- messages ----------

/** What the sender says about a blob, so the right alerts are used. Never content. */
export type Hint = "file" | "image";

/**
 * iPhones: always a notification (the NSE decrypts it: text with tap-to-copy; for photos and
 * files, "You received <name> from <device>" and it starts the download). Photos and files
 * also get a Live Activity (push-to-start, iOS 17.2+) that shows the download and carries
 * Copy / Save / Cancel. Android gets one data message.
 */
export function buildMessages(to: Recipient, env: Envelope, now: number, hint?: Hint): object[] {
  const envString = JSON.stringify(env);
  const expiry = now + TTL_SECONDS;

  if (to.platform === "android") {
    return [
      {
        token: to.fcm,
        data: { env: envString },
        android: { priority: "HIGH", ttl: `${TTL_SECONDS}s` },
      },
    ];
  }

  const messages: object[] = [
    {
      token: to.fcm,
      apns: {
        headers: {
          "apns-priority": "10",
          "apns-push-type": "alert",
          "apns-expiration": String(expiry),
          "apns-collapse-id": `teleport-${env.id}`,
        },
        payload: {
          aps: {
            // Generic text; the Notification Service Extension replaces it after decrypting.
            alert: { title: "Teleport", body: ALERT_BODY[env.k] },
            "mutable-content": 1,
            sound: "default",
            category: "CLIP",
            "thread-id": "teleport",
          },
          env: envString,
        },
      },
    },
  ];

  if (env.k === "blob" && (hint === "file" || hint === "image") && to.la) {
    // Field names per Firebase's Live Activity guide. The widget shows the sender's name by
    // looking `from` (a public-key fingerprint) up in its own store. Silent: the
    // notification above already alerted.
    messages.push({
      token: to.fcm,
      apns: {
        live_activity_token: to.la,
        headers: { "apns-priority": "10" },
        payload: {
          aps: {
            timestamp: now,
            event: "start",
            "content-state": { env: envString },
            "attributes-type": "ClipActivityAttributes",
            attributes: { kind: hint, from: env.from },
            alert: { title: "Teleport", body: hint === "file" ? "Downloading a file" : "Downloading a photo" },
            "stale-date": now + 3600,
            "dismissal-date": now + 3600,
          },
        },
      },
    });
  }
  return messages;
}

// ---------- OAuth ----------

let cached: { token: string; exp: number; email: string } | null = null;

const b64url = (data: ArrayBuffer | Uint8Array | string): string => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

function pemToDer(pem: string): ArrayBuffer {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

export async function signServiceAccountJwt(sa: ServiceAccount, now: number): Promise<string> {
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${claims}`));
  return `${head}.${claims}.${b64url(sig)}`;
}

async function accessToken(sa: ServiceAccount, now: number): Promise<string> {
  // Per-isolate cache only; nothing persisted.
  if (cached && cached.email === sa.client_email && cached.exp - 60 > now) return cached.token;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: await signServiceAccountJwt(sa, now),
    }),
  });
  if (!res.ok) throw new Error(`oauth ${res.status}`);
  const json = (await res.json()) as { access_token: string; expires_in: number };
  cached = { token: json.access_token, exp: now + json.expires_in, email: sa.client_email };
  return json.access_token;
}

export type SendResult = { ok: true } | { ok: false; status: number; error: string };

export async function sendAll(sa: ServiceAccount, messages: object[], now: number): Promise<SendResult[]> {
  const token = await accessToken(sa, now);
  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  return Promise.all(
    messages.map(async (message): Promise<SendResult> => {
      const res = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ message }),
      });
      if (res.ok) return { ok: true };
      // Surface only FCM's error code, never payloads. The specific code lives in
      // details[].errorCode (e.g. THIRD_PARTY_AUTH_ERROR = missing/invalid APNs key,
      // UNREGISTERED = dead token); `status` alone is too vague (UNAUTHENTICATED, NOT_FOUND).
      const body = (await res.json().catch(() => ({}))) as {
        error?: { status?: string; details?: { errorCode?: string }[] };
      };
      const code = body.error?.details?.find((d) => d.errorCode)?.errorCode;
      return { ok: false, status: res.status, error: code ?? body.error?.status ?? "UNKNOWN" };
    }),
  );
}
