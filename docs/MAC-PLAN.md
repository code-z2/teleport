# Teleport for Mac + multiple devices — design

Status: **proposal, not built.** Review this before implementation starts.

## Scope

**In:**
- **Several paired devices per install.** Today there's exactly one peer. With
  this change, pairing takes a single QR scan plus an "Allow" prompt.
- **A Mac menu bar app** that sends and receives clips (text, links, images)
  with both phones, at any distance.
- **Remote files.** From either phone, browse the Mac's home folder,
  **download** any file, and **upload** into any folder.
- **Instant reachability.** The phone knows right away whether the Mac is
  online.
- **Share sheet:**
  - iOS: "Teleport…" in the actions list opens a device picker. Every paired
    device also appears by exact name in the suggestions row.
  - Android: one Direct Share target per paired device.

**Out (decided):** terminal/shell, fixed actions, screen control.

## 1. Device model

- A device is identified by `fp(ks)`, the fingerprint of its signing key. The
  envelope's `from` field already carries it.
- Each install stores **a list of peers** (`fp → Peer`) instead of a single
  peer.
  - iOS: App Group defaults.
  - Android: SharedPreferences.
  - Mac: Application Support.
- **Opening an envelope:** look up `from` in the peer list, verify with that
  peer's `ks`, and reject anything unknown.
- **Removing a device:** delete it from the list. It can no longer send to
  this device, and it disappears from the share sheet.
- **`Peer` gains:**
  - `platform: "ios" | "android" | "mac"`
  - `mailbox` (Mac only, see §3)
  - `pairedAt`
- **Device names (decided):** each device sends its **exact name** when it
  pairs, and sends it again when it's renamed.
  - Every app has an editable "This device's name" setting.
  - Defaults:
    - Android: the device name from Settings, falling back to the model
      ("Pixel 8").
    - Mac: the computer name ("Peso's MacBook").
    - iPhone: asked for on first launch, because iOS only tells apps "iPhone".
- **Share entries:**
  - The Android Direct Share row and the iOS suggestions row show one entry per
    device under its exact name: "Pixel 8", "Peso's iPhone", "Kizola's iPhone".
  - The iOS **actions list** can't have names that change at runtime: an
    extension's name is fixed when the app is built. It gets one entry,
    **"Teleport…"**, which opens a small picker listing every device by its
    exact name.

## 2. Pairing v2: one scan, then Allow

The QR code is now `teleport2:<b64u(JSON)>`:

```json
{ "v":2, "name":"Peter's MacBook", "platform":"mac",
  "ka":b64u(65), "ks":b64u(65),
  "fcm"?:"…", "la"?:"…",        // phones: push addresses
  "mailbox"?:"…",                 // Mac: its relay mailbox id (= fp(ks))
  "ps":b64u(16) }                 // one-time pairing secret, valid 10 min, single use
```

**Flow:** A shows the QR code; B scans it.

1. B stores A as **pending** and sends A a `pair` envelope. It's sealed to
   `A.ka` and signed by `B.ks`, the same as any other envelope. The plaintext
   is:
   ```json
   { "card": <B's card without ps>, "proof": b64u(HMAC-SHA256(ps, utf8(canonical card JSON))) }
   ```
2. A checks:
   - the signature against the `ks` inside the card;
   - that the proof matches A's **current, unused** `ps` (then marks it used);
   - the usual freshness and replay checks.
3. A shows **"Pixel 8 wants to pair with this Mac. Allow?"**
   - On a phone, this arrives as a push notification with an Allow action.
   - On the Mac, it's a dialog.
4. On **Allow**, A stores B and replies with `pair-ok`, which contains A's
   current tokens. B then moves A from pending to paired. On **Deny**, or after
   10 minutes, B drops the pending entry.

`ps` is only ever shown on A's screen. A stranger who learns A's push address
still can't pair, because they can't produce the proof. Allow is the second
gate.

**New envelope kinds:** `pair` and `pair-ok`. The rule "the signature is
checked against a known peer" gets one exception: for `pair` only, the key
comes from the card inside, and the card is trusted only after the proof
checks out.

**Migration:** v1 pairings are dropped. Re-pair once (each pair is one scan).

## 3. Relay: the Mac's live connection (Durable Object)

The Mac doesn't receive pushes. It keeps a WebSocket open to a **`MacMailbox`
Durable Object**, one per Mac, named by its mailbox id. The object holds
connections and nothing else: no content and no persistent storage beyond
WebSocket attachments.

| Method | Path | Who | Purpose |
|---|---|---|---|
| GET (WebSocket) | `/v1/mailbox/:id/connect` | Mac | Opens the Mac's live connection. The Mac must prove it owns the mailbox (see below). |
| GET | `/v1/mailbox/:id/status` | phone | Returns `{ online, since }`. Instant reachability. |
| POST | `/v1/send` with `to.platform:"mac", to.mailbox` | phone | Forwards the envelope to the Mac's connection. Returns **`503 {"error":"offline"}`** if it isn't connected. |
| GET (WebSocket) | `/v1/mailbox/:id/session` | phone | Opens a file session; the Durable Object relays frames both ways (§4). |

- **Proving the mailbox:**
  1. On connect, the Durable Object sends a random challenge.
  2. The Mac replies with an ECDSA signature over it using `ks`.
  3. The Durable Object checks that `fp(ks) == :id` and that the signature
     verifies. A newer valid connection replaces the old one.
- **Hibernation:** keep-alives use the WebSocket Hibernation API with an
  automatic ping/pong response, so an idle Mac connection doesn't keep the
  object awake or billed.
- **Mac → phone** still goes through `/v1/send` and FCM, unchanged.
- **"Not reachable" UX:**
  - Sends return `offline` immediately, and the phone says "Mac is offline".
  - The phone file browser checks `status` before connecting.
  - Phone ↔ phone delivery receipts aren't part of this work.

**Cost (free plan):** Durable Objects backed by SQLite are on the Workers Free
plan, with 100k requests per day. Incoming WebSocket messages are billed at
20:1, and idle objects that can hibernate aren't billed for duration.
- A 1 GB transfer in 256 KiB chunks is about 4,096 messages, roughly 205
  billed requests.
- An idle Mac costs about nothing.

## 4. File sessions (phone ↔ Mac, end-to-end encrypted)

**Handshake** (signed ephemeral ECDH, so each session gets its own keys):

```
phone → Mac:  hello  { from: fp(phone.ks), epk_p, n_p (16B), ts, sig_p = ECDSA(phone.ks, "tp-sess-1"‖epk_p‖n_p‖ts‖mailbox) }
Mac → phone:  accept { epk_m, n_m, sig_m = ECDSA(mac.ks, "tp-sess-1"‖transcript‖epk_m‖n_m) }
keys:         HKDF-SHA256(ECDH(e_p, e_m), salt = SHA256(transcript), info = "teleport/v1/session")
              → 64 bytes: k_p→m ‖ k_m→p
```

- The Mac only accepts phones in its peer list.
- **Forward secrecy:** the ephemeral keys are discarded after the session.
- **Frames:** AES-256-GCM. The nonce is a 4-byte direction tag followed by an
  8-byte counter, and the receiver requires the counter to strictly increase.
  Control messages are JSON; data chunks are binary.

**Operations** (all paths are relative to `~`):

| Request | Response |
|---|---|
| `list { path }` | `entries [{ name, dir, size, mtime }]`, sorted with folders first |
| `download { path, offset? }` | `meta { size, mime }`, then chunks (256 KiB), then `done { sha256 }`. `offset` resumes an interrupted download. |
| `upload { dir, name, size }` | `ready { name }` (the final name; a clash becomes `name (2).ext`), then the phone sends chunks, then `done { sha256 }`. The Mac writes to a temp file and renames it only once the hash matches. |
| `cancel { id }` | Stops the transfer. |
| Any failure | `error { code, message }` |

**Path rules, enforced on the Mac:**
- Reject absolute paths and `..`.
- Resolve symlinks, and reject anything that ends up outside `~`.
- **Hidden by default:** dotfiles and dot-folders (`~/.ssh`, `~/.aws`, …) and
  `~/Library`. There's a Mac setting to show them.
- There's no size cap; transfers are streamed. A cancelled upload leaves no
  partial file.

## 5. Mac app

- A SwiftUI `MenuBarExtra` app at `mac/`, using `TeleportCore` (the package
  already builds for macOS). It lives **only in the menu bar**: no Dock icon
  (`LSUIElement`) and no app switcher entry.
- **Keys:** Secure Enclave, the same code as iOS. Apple-silicon and T2 Macs
  are supported.
- **Menu:**
  - online indicator;
  - **Send clipboard to ▸** (one entry per device);
  - Pair new device… (shows the QR code);
  - Devices (remove);
  - Settings: show hidden files, keep awake on power, start at login.
- **Receive:** text and links go on `NSPasteboard` immediately. Images go on
  the pasteboard and can also be saved to `~/Downloads/Teleport`. A
  notification confirms each one.
- **Send:** a macOS Share extension, "Teleport", with a device picker, plus the
  menu above.
- **Background:**
  - Starts at login (`SMAppService`).
  - Keeps the Mac awake while on power (an `IOPMAssertion` that prevents idle
    sleep).
  - Reconnects automatically with backoff after sleep or wake and network
    changes.
- **Distribution:** signed with your Developer ID and **not sandboxed**, so it
  can reach the whole home folder. macOS still asks once for Desktop,
  Documents and Downloads.

## 6. Phone changes

**iOS:**
- Pairing v2 screens: show my QR code, scan, waiting for Allow, and an
  incoming Allow prompt.
- A device list with remove.
- The actions-list entry becomes **"Teleport…"**, which opens a device
  picker with exact names.
- One suggestion per peer in the suggestions row.
- A **Mac browser**:
  - folder list with breadcrumbs;
  - tap a file to download, with progress, then Share / Save to Files / Save
    to Photos;
  - **Upload here** from Files or Photos.
- The Live Activity and notifications show which device a clip came from.

**Android:**
- The same pairing v2 screens and device list.
- One **Direct Share target per peer**, with the shortcut id set to the
  device's fingerprint.
- A **Mac browser** activity:
  - downloads go to `Downloads/Teleport` (MediaStore);
  - uploads use the system file picker;
  - progress is shown in the activity and as a notification.

## 7. Protocol updates and tests

- `protocol/SPEC.md` gets a v2 section covering the card, `pair` / `pair-ok`,
  the mailbox API, the session handshake and frames, and the file operations.
- `protocol/vectors.json` gains:
  - pair proofs (valid and invalid);
  - session handshakes with fixed ephemeral keys;
  - frame encrypt/decrypt;
  - path-rule cases (`..`, symlink escapes, hidden paths).
- The TS reference, Swift (iOS and Mac) and Kotlin must all pass.
- Worker tests cover:
  - mailbox ownership (the challenge);
  - `offline` responses;
  - session relaying;
  - hibernation keep-alive.

## 8. Build phases

| # | Phase | Done when |
|---|---|---|
| 1 | Multiple devices + pairing v2 on iPhone, Pixel and Worker | iPhone ↔ Pixel re-paired with one scan; clips still work both ways; vectors pass on all three |
| 2 | `MacMailbox` Durable Object | `connect`, `status`, `send` to a Mac and `session` relaying pass Worker tests; deployed |
| 3 | Mac app: pairing, clips both ways, online status, login item, keep awake | iPhone and Pixel send clips and images to the Mac and back from miles away; "Mac is offline" shows instantly when it's off |
| 4 | Share sheet: "Teleport…" device picker on iOS, Mac in suggestions and Direct Share | Both phones can share to any device, by exact name, in one or two taps |
| 5 | File sessions: list, download and upload with progress on both phones | Browse `~` from cellular, pull a large file, upload into a chosen folder, cancel cleanly |

Each phase ships on its own and is tested on the real devices before the next
one starts.

## Open questions

- ~~Default phone for the "Teleport" action~~: decided. "Teleport…" opens a
  device picker with exact names (see §1).
- **Mac → phone large files:** sending a big file *from* the Mac to a phone
  (rather than pulling it) would go through R2 with the current 10 MB cap.
  Raise it later with multipart uploads if needed.
