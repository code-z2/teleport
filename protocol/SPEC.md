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
| POST | `/v1/blob/upload` | — | `{ "id":"…", "upload":"…" }`: starts a large upload (see "Large blobs") |
| PUT | `/v1/blob/upload/:id/:upload/:part` | ciphertext bytes (≤ 32 MiB) | `{ "etag":"…" }` |
| POST | `/v1/blob/upload/:id/:upload/complete` | `{ "parts":[{ "part":1, "etag":"…" }, …] }` | `{ "ok":true }` |
| DELETE | `/v1/blob/upload/:id/:upload` | — | `204` (abandons it) |
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

---

# v2 additions: multiple devices and single-scan pairing

The envelope format is unchanged (`"v":1`). v2 adds a new pairing card, two
envelope kinds, and the rule that each install keeps **a list of peers keyed by
`fp(ks)`** instead of a single peer.

## Kinds

`text`, `blob`, `peer`, **`pair`**, **`pair-ok`**, **`pair-no`**.

## Pairing card v2 (QR)

```
teleport2:<b64u(utf8(JSON))>
JSON = { "v":2, "name":"Pixel 8", "platform":"ios"|"android"|"mac",
         "ka":b64u(65), "ks":b64u(65),
         "fcm"?:"…", "la"?:"…", "mailbox"?:"…",
         "ps"?:b64u(16) }
```

- `ps` is the **pairing secret**. It's present only in the QR code: 16 random
  bytes, valid for 10 minutes, usable once. It's never sent over the network.
- A card sent *inside* a message omits `ps`.
- v1 cards (`teleport1:`) are rejected. v1 pairings must be redone.

## Flow

A shows the QR code; B scans it.

1. B stores A as **pending** and sends A a `pair` envelope. It's sealed to
   `A.ka` and signed by `B.ks`, exactly like any other envelope (`from` =
   `fp(B.ks)`). The plaintext is:
   ```json
   { "card": "<B's card JSON, as a string, without ps>",
     "proof": b64u(HMAC-SHA256(key = ps, data = utf8(card string))) }
   ```
   The card is carried as a string so the proof covers exact bytes, with no
   JSON canonicalization needed.
2. A opens it with **`openPair`**. B isn't a known peer yet, so the order is:
   1. check `v` and `k == "pair"`;
   2. decrypt with A's `ka` (`decrypt` on failure);
   3. parse the card (`encoding` on failure);
   4. check `fp(card.ks) == from` (`peer` on failure);
   5. verify `sig` against `card.ks` (`signature`);
   6. check freshness (`stale`);
   7. check that the proof matches A's current unused `ps` (`proof`); then the
      replay cache.
3. A asks the user **"<card.name> wants to pair. Allow?"**
4. On Allow, A stores B and sends B a `pair-ok` envelope. Its plaintext is A's
   card JSON without `ps`, carrying A's current tokens and name. B opens it like
   any other envelope, using A's `ks` from the scanned QR code, then promotes A
   from pending to paired.

5. On Deny, A sends B a **`pair-no`** envelope (plaintext `{}`), sealed to `B.ka` and
   signed by `A.ks` like `pair-ok`. B opens it with A's `ks` from the QR code, drops A
   from pending and tells the user "<A> declined". Without it, B would wait until the
   10-minute pending window ran out.

## `peer` (updates)

The plaintext is `{ "name"?, "fcm"?, "la"?, "mailbox"? }`. Send it to every
peer when the device is renamed or its push tokens rotate. Missing fields keep
their previous values.

## Relay

`/v1/send` accepts the new kinds. On iOS, `pair` and `pair-ok` arrive as alert
pushes ("Pairing request" / "Paired") with the envelope in `env`, and never as
Live Activities.

---

# Mac mailbox (phase 2)

A Mac doesn't receive pushes. It keeps a WebSocket open to a **mailbox**, a
Cloudflare Durable Object named by the Mac's id, `fp(mac.ks)`. The mailbox
relays bytes between the Mac and phones and never sees plaintext. It stores
nothing apart from the attachments on the open WebSocket connections.

Every request carries `Authorization: Bearer <RELAY_KEY>`. `:id` is 11 base64url
characters.

## Mac connection: `GET /v1/mailbox/:id/connect` (WebSocket)

The Mac proves it owns the mailbox:

```
mailbox → Mac   {"t":"challenge","nonce":b64u(32)}
Mac → mailbox   {"t":"auth","ks":b64u(65),"sig":b64u(64)}
                sig = ECDSA-P256-SHA256(mac.ks, utf8("teleport/v1/mailbox|" + id + "|" + nonce)), raw r‖s
mailbox → Mac   {"t":"ready"}
```

- The mailbox requires `fp(ks) == id` and a valid signature. On failure it
  closes the connection with code **4401**.
- A connection that hasn't authenticated within 30 s is closed with **4408**.
- A newer authenticated connection replaces the older one, which is closed
  with **4000** "replaced".
- **Keep-alive:** the Mac sends the text `ping` and gets `pong`. The mailbox
  answers automatically, without waking up (hibernation).

## Status: `GET /v1/mailbox/:id/status`

Returns `{"online": true|false, "since": <unix seconds>|null}`. `since` is when
the current Mac connection authenticated.

## Delivering envelopes: `POST /v1/send` with `to: {"platform":"mac","mailbox":":id"}`

- If the Mac is connected, it receives `{"t":"env","env":<Envelope>}` and the
  sender gets `200 {"ok":true}`.
- Otherwise the sender gets **`503 {"ok":false,"error":"offline"}`**. Nothing
  is queued.

## Sessions: `GET /v1/mailbox/:id/session` (WebSocket, phone)

A session is a byte pipe between one phone and the Mac. Its contents (the
handshake, encrypted frames and file operations) are specified under "File sessions". The
mailbox only routes them.

- **Mac offline:** the session request gets `503 {"ok":false,"error":"offline"}`
  instead of a WebSocket.
- **Opening:** the mailbox gives the session a random 16-byte `sid` and tells
  the Mac `{"t":"open","sid":b64u(sid)}`.
- **Phone → Mac:** the phone sends **binary** messages. The Mac receives
  `sid ‖ payload`.
- **Mac → phone:** the Mac sends binary `sid ‖ payload`. The phone receives
  `payload`.
- **Closing:**
  - When the phone disconnects, the Mac gets `{"t":"close","sid":…}`.
  - The Mac can send `{"t":"close","sid":…}`, and the mailbox then closes the
    phone's connection with code 1000.
  - If the Mac disconnects, every session is closed with **4410**.
- **Limits:**
  - At most 8 sessions per mailbox; the next one gets `429`.
  - At most 1 MiB per message.
  - A text message from the phone closes the session with **4400**.

# File sessions (v2)

A phone browses the Mac's home folder through a mailbox session (above). Everything
inside the session is end-to-end encrypted; the relay sees only opaque frames.

## Handshake

The first binary message each way is plain JSON (UTF-8).

```
phone → Mac: {"t":"hello","v":1,"from":fp(phone.ks),"epk":b64u(65B),"n":b64u(16B),"ts":unix,"sig":b64u}
Mac → phone: {"t":"accept","epk":b64u(65B),"n":b64u(16B),"sig":b64u}
           or {"t":"error","code":"denied"|"stale"|"signature"|"version"} and the Mac closes the session
```

- `H` = UTF-8 `teleport/v1/session|<mailbox>|<from>|<epk>|<n>|<ts>` (the strings exactly as sent).
- `hello.sig` = ECDSA(phone.ks, `H`), raw r‖s.
- `A` = `H` ‖ UTF-8 `|<accept.epk>|<accept.n>`; `accept.sig` = ECDSA(mac.ks, `A`).
- The Mac accepts only phones in its peer list (`from` = fp of a paired phone's
  `ks`) with `|ts − now| ≤ 300`. The phone verifies `accept.sig` with the Mac's
  paired `ks`. Binding the mailbox id into `H` stops a hello being replayed to
  another Mac.
- Keys: `okm = HKDF-SHA256(ikm = ECDH(own ephemeral, other epk), salt = SHA256(A),
  info = "teleport/v1/session", 64 bytes)`; `k_p2m = okm[0..32]`, `k_m2p = okm[32..64]`.
  Ephemeral keys are discarded when the session ends (forward secrecy).

## Frames

Every later binary message is `AES-256-GCM(k_dir, nonce, plaintext, aad = empty)`
as ciphertext ‖ tag.

- `nonce = dir (u32 BE) ‖ counter (u64 BE)`; `dir` = 1 phone→Mac, 2 Mac→phone.
- `counter` is implicit: 0 for the first frame in each direction, +1 per frame.
  WebSockets are ordered, so a dropped, replayed or reordered frame fails to
  decrypt, and either side then closes the session.
- Plaintext is `0x01 ‖ JSON` (control) or `0x02 ‖ id (u32 BE) ‖ bytes` (data).
- At most 256 KiB of data per frame.

## Operations

Requests carry an `id` (u32) chosen by the phone; replies and data use the same id.
All paths are relative to the Mac user's home folder, `/`-separated; `""` is home.

| Phone sends | Mac replies |
|---|---|
| `{"op":"list","id","path"}` | `{"op":"entries","id","path","entries":[{"name","dir","size","mtime"}]}`, folders first, then by name |
| `{"op":"download","id","path","offset"?}` | `{"op":"meta","id","size","mime"}`, data frames from `offset`, then `{"op":"done","id","sha256"}` (SHA-256 of the whole file, b64u). To resume a download cut off part-way, the phone keeps the bytes it has, rehashes them and asks again with `offset` |
| `{"op":"upload","id","dir","name","size"}` | `{"op":"ready","id","name"}` (the final name; a clash becomes `name (2).ext`). The phone sends data frames, then `{"op":"done","id","sha256"}`; the Mac checks the hash, moves the file into place and replies `{"op":"saved","id","name"}` |
| `{"op":"endpoints","id"}` | `{"op":"endpoints","id","hosts":["192.168.1.20:49390", …]}`: where this computer accepts direct sessions (see "Direct connections"); empty if none |
| `{"op":"read","id","path","offset","size"}` | Up to 2 MiB (`size`, capped) from `offset` as data frames, then `{"op":"done","id"}`; no acks (it fits one window). For streaming: a player reads what it needs next, including after seeking |
| `{"op":"thumbnail","id","path","px"}` | A Quick Look thumbnail as JPEG, longest side `px` (64–1024, default 512): `meta` (`mime` `image/jpeg`), data frames, `done`, as for a download but without acks. `{"op":"error","code":"unsupported"}` if the Mac can't render one |
| `{"op":"cancel","id"}` | Either side may send it. The transfer stops; a cancelled upload leaves no file |
| | `{"op":"error","id","code","message"}`, `code` ∈ `not_found`, `denied`, `bad_path`, `exists`, `io`, `hash`, `busy`, `unsupported` |

**Flow control.** The receiver of data sends `{"op":"ack","id","bytes"}` (total
bytes received so far) at least every 1 MiB. The sender keeps at most 2 MiB
unacknowledged, so neither the relay nor the receiver buffers a whole file.

## Path rules (enforced by the Mac)

- Reject absolute paths, NUL bytes and any `..` component; drop empty and `.` components.
- Unless "Show hidden files" is on, reject any component starting with `.` and
  a top-level `Library`.
- Resolve symlinks and reject anything whose real path is outside the home folder.
- Listings omit what the rules would reject.

# Large blobs (up to 250 MB)

Clips over 10 MB, and any file, can be sent as a **chunked blob**. The envelope is still a
`blob` envelope; its pointer gains two fields:

```json
{ "id":"…", "mime":"video/mp4", "size":<bytes>, "key":b64u(32), "n":b64u(12),
  "c":4194304, "name"?:"Holiday.mp4" }
```

- `c` is the plaintext chunk size. Its presence means the chunked format; pointers
  without it use the single AES-GCM format above, so small clips are unchanged.
- `name` is the original file name, if there was one.
- `size` is at most 250 MiB (262 144 000 bytes); larger sends are refused by the sender.

**Format.** The plaintext is split into `count = max(1, ceil(size / c))` chunks; every
chunk but the last is exactly `c` bytes (an empty file is one empty chunk). The blob body
is the concatenation of, for chunk `i` (from 0):

```
nonce_i = n[0..4] ‖ (n[4..12] XOR u64be(i))
aad_i   = "teleport/v1/blob" ‖ u64be(i) ‖ (i == count − 1 ? 0x01 : 0x00)
AES-256-GCM(key, nonce_i, chunk_i, aad_i)          (ciphertext ‖ 16-byte tag)
```

The receiver knows `size` and `c` from the signed pointer, so it reads exactly
`size + 16 × count` bytes and opens each chunk in order. A reordered, dropped, repeated
or truncated chunk fails to authenticate, as does a stream that ends early, because the
final chunk's AAD carries the end marker. Both sides stream: neither needs the whole file
in memory.

**Upload.** Through R2 multipart uploads, because the relay can't accept a 250 MB body in
one request: `POST /v1/blob/upload`, then the body in parts of 16 MiB (every part but the
last the same size, as R2 requires), then `complete`. The relay refuses a completed blob
over 250 MiB + overhead and deletes it. `GET /v1/blob/:id` streams it back; the recipient
deletes it after download, and the 1-day lifecycle rule is the backstop.

**Delivery.** Large files go to Downloads (Mac, Windows, Android) or are offered from the
notification (iPhone); only images that fit the old limit go to the clipboard.

# Direct connections (same network)

Through the relay, a computer can send only as fast as its internet upload (often well under
1 MB/s at home), too slow for high-bitrate video. On the same network the phone connects
straight to the computer instead:

1. The phone opens a session through the relay as usual and sends `endpoints`. The reply
   comes over that encrypted, authenticated session, so the addresses can be trusted.
2. It tries each `ip:port` (private IPv4 only) with a short timeout. The first that answers
   gets a **new session**: the same `hello` / `accept` handshake (bound to the same mailbox
   id), keys and frames, over one TCP connection where each message is framed as
   `u32 BE length ‖ payload` (at most 4 MiB). The relayed session is then closed.
3. If none answers (another network, client isolation, a firewall), the phone stays on the relay.
   If the direct connection drops, the next operation reconnects, through the relay if need be.

The computer's listener accepts any TCP connection but serves nothing until a paired phone's
signed `hello` checks out, exactly as for relay sessions.
