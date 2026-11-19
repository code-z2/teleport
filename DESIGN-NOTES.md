# teleport — design notes (review of the hand-off spec)

## Verdict on React Native

**Not effortless, and not worth it.** Most of the logic runs in places RN can't
(or shouldn't) run:

| Piece | Runs in | RN? |
|---|---|---|
| Send (share sheet) on iOS | Share Extension (~120 MB limit) | No. Hermes plus the bridge is too heavy and fragile there. Write it in Swift. |
| Receive on iOS | Notification Service Extension (**~24 MB**, ~30 s) | No. Swift only. |
| Receive on Android | `FirebaseMessagingService.onMessageReceived` | Possible via headless JS, but it's slower and less reliable. Write it in Kotlin. |
| Send on Android | Transparent `ACTION_SEND` activity | Possible, but a cold RN start adds latency. Write it in Kotlin. |
| Secure Enclave / StrongBox crypto | Native APIs | You'd write a native module anyway. |
| Pairing QR screen, settings | Main app | RN would help, but this is the smallest part. |

RN only helps with the ~10–15% of the code that is UI. You'd still write the
Swift and Kotlin, plus the bridge glue. **Recommendation:** native SwiftUI and
native Kotlin/Compose (both apps stay small), a TypeScript Worker, and one
shared wire-format spec with **cross-platform test vectors**.

## Corrections to the spec

1. **The Secure Enclave can't hold an AES key.** It only stores P-256 keys.
   The "shared 256-bit master secret in `kSecAttrTokenIDSecureEnclave`" idea
   doesn't work as written. Your asymmetric approach is the right fix:
   - Each device makes a hardware P-256 key-agreement key (SE on iOS;
     StrongBox `PURPOSE_AGREE_KEY` on Android, API 31+). The QR pairing swaps
     only the **public** keys.
   - Sender: makes an ephemeral P-256 key, does ECDH with the recipient's
     public key, then HKDF-SHA256 to get a 32-byte key, then AES-256-GCM with
     a random 12-byte nonce. The sender doesn't need its hardware key to
     encrypt.
   - Recipient: does ECDH in the SE or StrongBox with the ephemeral public
     key, then the same HKDF, then decrypts.
2. **Use the CryptoKit hybrid route, not `eciesEncryptionCofactorX963SHA256AESGCM`.**
   - Apple's ECIES with P-256 uses an **AES-128** key, not 256.
   - Its output format and IV derivation are Apple-specific, so Kotlin would
     have to copy them byte for byte.
   - Explicit ECDH, HKDF and AES-GCM is easy to match in JCA/Kotlin.
3. **Add sender authentication.** ECIES to the recipient's key alone shows
   who a clip is *for*, not who sent it. Anyone who has the recipient's push
   token, public key and the Worker URL could inject clips. Two options:
   - Sign `(ephemeralPub ‖ nonce ‖ ciphertext ‖ msgId ‖ ts)` with the
     sender's hardware P-256 signing key.
   - Use a static-static ECDH step, like HPKE auth mode.
   Bind the type, msgId and timestamp as AES-GCM AAD, and drop old or
   replayed msgIds.
4. **The 5-minute R2 TTL isn't possible.** R2 lifecycle rules work in
   **days** (minimum 1). Instead:
   - The recipient asks the Worker to DELETE the blob after downloading it.
   - A 1-day lifecycle rule acts as a backstop.
   - The blobs are encrypted, so lingering ones are only clutter.
5. **Push payloads are limited to ~4 KB** on both APNs and FCM. After
   encryption overhead and base64, inline text tops out around **~2.5 KB**.
   Larger text should go through R2 like images.
6. **Background clipboard writes on iOS aren't really possible.** The NSE
   can decrypt and show the clip in a rich notification. To copy, the user
   taps it, or taps a "Copy" action with `.foreground`, which opens the app
   and writes to `UIPasteboard`. Plan for **tap-to-copy on iOS**. Android can
   call `setPrimaryClip` straight from the FCM handler, but also post a
   notification. Otherwise Android may lower the priority of high-priority
   messages that never lead to anything the user sees.
7. **Send iOS pushes through FCM too, not straight to APNs.**
   - APNs requires HTTP/2.
   - Workers' outbound `fetch` has historically not offered HTTP/2 to
     origins. Check this before relying on it.
   - FCM HTTP v1 delivers to iOS via the APNs key you upload to Firebase, and
     it supports `mutable-content` for the NSE.
   - The Worker then needs one secret (the FCM service account) and one code
     path.
8. **Push tokens rotate.** In a stateless design, the peer must learn the new
   token. When a device's token changes, it sends a small encrypted
   "token-update" message to its peer. Otherwise you'll need to re-pair now
   and then.
9. **Delivery semantics.** A 200 from APNs/FCM means the push was accepted,
   not delivered. APNs keeps only the **latest** notification per device
   while it's offline, which is fine for a clipboard. "Retry" means the user
   re-shares the clip.

## iOS receive UX: Live Activity with a Copy button

Possible on iOS 17.2+ with **push-to-start**. It runs alongside the normal
notification, not from it.

- **Starting it.** The NSE can't start a Live Activity, because
  `Activity.request` needs the app in the foreground. Instead the server
  sends an `apns-push-type: liveactivity` push to the
  **push-to-start token**, which comes from
  `Activity<ClipAttributes>.pushToStartTokenUpdates`.
  - This is another rotating token the peer must learn, sent via the same
    encrypted token-update message.
  - FCM HTTP v1 does support Live Activity start/update/end through
    `apns.live_activity_token`, so everything stays on FCM.
- **Auto-expand.** On Dynamic Island devices, a start or update that carries
  an `alert` shows the **expanded** view for a few seconds, then shrinks to
  compact. Long-pressing expands it again. You can't keep it pinned open. On
  non-island devices it appears as a lock-screen or banner card.
- **The Copy button.** `Button(intent: CopyClipIntent(...))` with a
  `LiveActivityIntent` runs in the app's process without opening the app. It
  also works from the lock screen.
- **⚠ Spike first:** check on a real device that `UIPasteboard.general`
  writes succeed from a `LiveActivityIntent` running in the background. If
  they don't, fall back to an intent that opens the app (`.foreground`),
  which still takes one tap.
- **E2EE catch.** Your code never sees Live Activity `content-state` before
  it renders, because there is no NSE hook for it. So:
  - Put only the **ciphertext** (≤ ~3 KB) and an opaque id in
    `content-state`.
  - Show a generic "New clip" with no plaintext preview in the island.
  - The intent receives the ciphertext as a parameter, decrypts it with the
    SE key (keychain access group shared with the app), and copies it.
  - Images: the ciphertext slot holds the R2 blob id and the intent
    downloads the blob.
- **Housekeeping.**
  - Each new clip ends the previous activity.
  - Set `dismissal-date` to about 5 minutes.
  - Users can turn off Live Activities per app; keep the normal notification
    as the fallback.
  - Live Activity pushes have a frequency budget, which is fine at
    clipboard rates.

## Cost

Running costs are about $0. The one fixed cost is the **Apple Developer
Program at $99/yr**: push notifications and installs that don't expire every
7 days both need a paid account.

- Workers free tier: 100k requests/day.
- R2 free tier: 10 GB stored, 1M class-A operations/month, no egress fees.
- FCM and APNs: free.

## Proposed layout

```
teleport/
  protocol/   wire format spec + JSON test vectors (shared by both apps)
  worker/     Cloudflare Worker (TS): /send, /blob PUT/GET/DELETE → FCM v1, R2
  ios/        SwiftUI app + ShareExtension + NotificationServiceExtension
  android/    Kotlin app: share activity + FirebaseMessagingService
```
