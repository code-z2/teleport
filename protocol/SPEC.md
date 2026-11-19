# Teleport wire protocol v1

Every implementation (Swift, Kotlin, and the TypeScript reference) must
pass `protocol/vectors.json`. Change the format → bump `v`, regenerate
vectors, update all three.

## Notation

- `b64u(x)`: base64url, no padding.
- `‖`: byte concatenation.
- **P-256 public keys** are 65-byte uncompressed SEC1 points
  (`0x04 ‖ X ‖ Y`).
- **Signatures** are ECDSA P-256 / SHA-256 in **raw** `r ‖ s` form (64
  bytes). Android Keystore produces DER, so convert.
- **AES-GCM**: 12-byte nonce, 16-byte tag appended to the ciphertext.

## Device keys

Each device holds two hardware-backed P-256 keys that never leave the
secure hardware.

| Key | Purpose | iOS | Android |
|---|---|---|---|
| `ka` | Key agreement: recipients decrypt with it | `SecureEnclave.P256.KeyAgreement.PrivateKey` | Keystore EC, `PURPOSE_AGREE_KEY`, StrongBox if available (API 31+) |
| `ks` | Signing: senders authenticate with it | `SecureEnclave.P256.Signing.PrivateKey` | Keystore EC, `PURPOSE_SIGN`, `DIGEST_SHA256`, StrongBox if available |

`fp(pub) = b64u(SHA-256(pub)[0..8])` is a short fingerprint of a public key.

## Pairing card (QR)

```
teleport1:<b64u(utf8(JSON))>
JSON = { "v":1, "name":"Pixel 9", "platform":"android"|"ios",
         "ka":b64u(65), "ks":b64u(65), "fcm":"<FCM token>", "la"?:"<iOS push-to-start token>" }
```

Both devices show their card and scan the other's. After pairing, each
device stores the peer's `ka`, `ks`, `fcm`, `la` and `platform`.

## Envelope

```json
{ "v":1, "id":b64u(16 random), "ts":<unix seconds>, "k":"text"|"blob"|"peer",
  "from":fp(sender ks), "epk":b64u(65), "n":b64u(12), "ct":b64u(..), "sig":b64u(64) }
```

### Seal (sender → recipient `R`)

```
H    = "teleport/v1|" + id + "|" + ts + "|" + k + "|" + from      (UTF-8)
e    = fresh software P-256 key pair;  epk = pub(e)
ss   = ECDH(e, R.ka).x                                            (32 bytes)
K    = HKDF-SHA256(ikm=ss, salt=epk ‖ R.ka, info="teleport/v1/aes-256-gcm", L=32)
ct   = AES-256-GCM(K, n, plaintext, aad=H)
sig  = ECDSA-P256-SHA256(sender.ks, H ‖ epk ‖ n ‖ ct)
```

### Open (recipient)

1. Check that `v == 1`, `k` is known, and `from` matches a paired peer.
2. Verify `sig` against that peer's `ks`. **Reject before decrypting.**
3. Check that `ts` is within [now − 24 h, now + 5 min], and that `id` hasn't
   been seen in the last 24 h (local replay cache).
4. Compute `ss = ECDH(own ka, epk)`, derive `K` as above, then decrypt with
   aad `H`.

### Plaintexts by `k`

- `text`: UTF-8 text.
- `blob`: UTF-8 JSON
  `{ "id":"<R2 id>", "mime":"image/png", "size":<bytes>, "key":b64u(32), "n":b64u(12) }`.
  The blob body is `AES-256-GCM(key, n, bytes, aad="teleport/v1/blob")`,
  with a fresh random `key` per blob.
- `peer`: UTF-8 JSON `{ "fcm":"…", "la"?:"…", "name"?:"…" }`. The sender
  sends this when its push token rotates.

### Size rule

The serialized envelope must be **≤ 3000 bytes**, because push payloads cap
at 4 KB. Text that would exceed this goes out as a `blob` with
`mime: "text/plain; charset=utf-8"`.

## Relay API (Cloudflare Worker)

Every request needs `Authorization: Bearer <RELAY_KEY>`. This only keeps
strangers off the relay; it is not a security boundary, because content is
E2EE and signed.

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/v1/send` | `{ "to": { "platform":"ios"\|"android", "fcm":"…", "la"?:"…" }, "env": Envelope }` | `{ "ok":true }` |
| PUT | `/v1/blob` | ciphertext bytes (≤ 10 MB) | `{ "id":"…" }` |
| GET | `/v1/blob/:id` | — | ciphertext bytes |
| DELETE | `/v1/blob/:id` | — | `204` |

Delivery through FCM HTTP v1:

- **Android:** a data message `{ env: JSON }` with priority `high` and a
  TTL of 300 s.
- **iOS alert:** `mutable-content: 1` and category `CLIP`, with the envelope
  in the custom key `env`. The Notification Service Extension decrypts it.
- **iOS Live Activity** (only when `la` is set and `k` is `text` or `blob`):
  sent through `apns.live_activity_token`, with `event: "start"`,
  `attributes-type: "ClipActivityAttributes"`, and
  `content-state: { "env": "<envelope JSON string>" }`.

R2 objects get deleted by the recipient after download. A 1-day bucket
lifecycle rule is the backstop.
