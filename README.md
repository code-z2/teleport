# Teleport

End-to-end-encrypted clipboard sync between an iPhone and an Android phone. You
share from the OS share sheet, a push notification delivers the clip, and the
other phone puts it on the clipboard. The relay is a stateless Cloudflare Worker
that never sees plaintext.

- [DESIGN-NOTES.md](DESIGN-NOTES.md): why it's native (not React Native), and
  the corrections to the original spec.
- [protocol/SPEC.md](protocol/SPEC.md): wire format, crypto and relay API.

```
protocol/   SPEC.md, vectors.json, TS reference implementation (generates the vectors)
worker/     Cloudflare Worker relay → FCM HTTP v1 (Android + iOS + Live Activities), R2 blobs
ios/        SwiftUI app, Share Extension, Notification Service Extension, Live Activity
            Packages/TeleportCore: protocol + Secure Enclave keys + relay client
android/    Kotlin app (Compose), share activity, FCM service
            core/: pure-JVM protocol + relay client; app/: Keystore/StrongBox keys, UI
```

All three implementations test against the same `protocol/vectors.json`.

## Tests

```bash
node --test protocol/reference/teleport.test.ts
```

```bash
cd worker && npm test
```

```bash
cd ios/Packages/TeleportCore && swift test
```

```bash
cd android && ./gradlew :core:test
```

## Setup

### 1. Firebase (push for both platforms)

1. Create a Firebase project. Add an **Android app** and an **iOS app** using
   your bundle ids.
2. Upload your **APNs auth key (.p8)** to Firebase → Project settings → Cloud
   Messaging.
3. Put `google-services.json` in `android/app/` and `GoogleService-Info.plist`
   in `ios/Teleport/`. Both are git-ignored.
4. Create a service account key with the *Firebase Cloud Messaging API Admin*
   role. The worker needs this JSON.

### 2. Worker

```bash
cd worker
npx wrangler r2 bucket create teleport-blobs
npx wrangler r2 bucket lifecycle add teleport-blobs expire-1d --expire-days 1
openssl rand -base64 36 | npx wrangler secret put RELAY_KEY
npx wrangler secret put FCM_SERVICE_ACCOUNT < path/to/service-account.json
npx wrangler deploy
```

Keep the `RELAY_KEY` value. Both apps need it. (Print it once with
`openssl rand -base64 36` and paste it into both prompts if you prefer.)

### 3. iOS

```bash
cd ios
cp Config/Teleport.xcconfig.example Config/Teleport.xcconfig   # team id, bundle id, relay URL + key
xcodegen && open Teleport.xcodeproj
```

- Automatic signing creates the App Group (`group.<bundle id>`) and the keychain
  group.
- Run the app on a real device. The simulator has no Secure Enclave and no push.

### 4. Android

```bash
cd android
cp teleport.properties.example teleport.properties              # applicationId, relay URL + key
./gradlew :app:installDebug
```

### 5. Pair

Open both apps. Each shows a QR code: scan the iPhone's code from the Android
app, then scan the Android code from the iPhone.

## Open items

- **Spike first:** check whether `UIPasteboard` writes work from
  `CopyClipIntent` (the Live Activity button) while the app is in the
  background. If they don't, give the intent `supportedModes = .foreground`.
- **Live Activity payload:** confirm the push-to-start fields in
  `worker/src/fcm.ts` against Firebase's Live Activity guide.
- **Firebase Android deprecations:** `FirebaseMessaging.token` and `onNewToken`
  show as deprecated with BOM 35.2. Move to the replacement API.
- **App icons:** none yet. Both apps use placeholders.
