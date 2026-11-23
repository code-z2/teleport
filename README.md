# Teleport

End-to-end-encrypted clipboard, photo and file sharing between iPhone, Android,
Mac and Windows, plus browsing and streaming your computers' files from your
phone. The relay is a Cloudflare Worker that only ever handles ciphertext.

- [DESIGN-NOTES.md](DESIGN-NOTES.md): why it's native (not React Native), and
  the corrections to the original spec.
- [protocol/SPEC.md](protocol/SPEC.md): wire format, crypto, relay API, file
  sessions and direct connections.

## What it does

- **Send anything to any paired device.** Use the share sheet, the Share menu, or
  Services on the Mac. On the phones you can also use the Control Center control
  (iPhone) or the Quick Settings tile (Android) to send what you just copied.
  - Text goes onto the other device's clipboard.
  - Photos and files up to 250 MB go to Downloads (computers) or the inbox
    (phones).
- **Notifications on the iPhone.**
  - Text arrives as a notification: tap to copy.
  - Photos and files start a Live Activity with download progress, then Copy,
    Save and Cancel.
- **Browse a computer from your phone.** You can open your Mac's or PC's home
  folder; the PC also shows its drives.
  - Preview a file before saving it, and upload files to the computer.
  - Downloads resume where they left off after a dropped connection.
- **Stream video and audio** from the computer while it's still downloading.
- **Direct connections on the same Wi‑Fi.** Browsing and streaming move off the
  relay onto your local network, so they run at Wi‑Fi speed instead of your home
  internet's upload speed.
  - The computer sends its local addresses over the encrypted relay session.
    Nothing is advertised on the network: no Bonjour/mDNS.
  - If no address answers within a few seconds, the session stays on the relay.
- **Pairing** uses a QR code and Allow / Deny on the device being paired. Codes
  refresh once used or expired.

Every message is signed and encrypted end to end (P-256 ECDH, HKDF, AES-GCM,
ECDSA). Device keys live in hardware where there is some: the Secure Enclave on
Apple devices, Keystore/StrongBox on Android, the TPM on Windows.

## Layout

```
protocol/   SPEC.md, vectors.json, TypeScript reference implementation (generates the vectors)
worker/     Cloudflare Worker relay: Durable Object mailboxes, R2 blobs, FCM HTTP v1 push
            (Android, iOS, Live Activities)
ios/        SwiftUI app (iOS 16+), Share and Action extensions, Notification Service
            extension, Live Activity and Control Center widget
            Packages/TeleportCore: protocol, keys, relay client, file sessions (shared with the Mac)
            Legacy/: iOS 16 versions of views that use newer APIs, chosen with #available
mac/        Menu bar app (macOS 15+) and Share extension, built on TeleportCore
android/    Kotlin app (Compose, Android 13+), share activity, Quick Settings tile, FCM service
            core/: pure-JVM protocol + relay client; app/: Keystore/StrongBox keys, UI
windows/    .NET 9 tray app (WPF): Teleport.Core (protocol, file server), Teleport.Windows (UI,
            TPM keys), Teleport.Core.Tests (xUnit)
tools/win   Build, test and run the Windows app on a PC over SSH from the Mac
```

Every implementation tests against the same `protocol/vectors.json`.

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

```bash
cd windows && dotnet test
```

To run the Windows tests on a PC from the Mac, use `tools/win test`.

## Setup

### 1. Firebase (push to the phones)

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
npx wrangler r2 bucket create teleport-blobs     # answer "no" when it offers to add a binding
npx wrangler r2 bucket lifecycle add teleport-blobs expire-1d --expire-days 1
openssl rand -hex 32                             # save this: the relay key
npx wrangler secret put RELAY_KEY                # paste it
npx wrangler secret put FCM_SERVICE_ACCOUNT < path/to/service-account.json
npx wrangler deploy
```

- Run all of these from `worker/`. Outside that folder, `npx` uses a global
  Wrangler that can't find `wrangler.jsonc`.
- Every app needs the relay URL and key. They're kept only in git-ignored
  config files, never in the repo.

### 3. iPhone

```bash
cd ios
cp Config/Teleport.xcconfig.example Config/Teleport.xcconfig   # team id, bundle id, relay URL + key
open Teleport.xcodeproj
```

- The project uses Xcode 27's JSON format
  (`Teleport.xcodeproj/project.xcproj`), so it's readable and diffs cleanly.
  Edit it in Xcode or by hand. After hand edits, run
  `xcrun xcprojformatter --update Teleport.xcodeproj`.
- Automatic signing creates the App Group (`group.<bundle id>`) and the keychain
  group.
- Run the app on a real device. The simulator has no Secure Enclave and no push.
- The first time you browse a computer, iOS asks for **Local Network** access.
  Allow it, or direct connections stay off and everything goes through the relay.

### 4. Mac

The Mac app reads the same `ios/Config/Teleport.xcconfig` (team, bundle id,
relay URL and key), so set up the iPhone config first.

```bash
cd mac
open TeleportMac.xcodeproj
```

- It runs in the menu bar.
- To browse your home folder, grant the access it asks for. Only your home folder
  is shared.
- Leave incoming connections allowed in the macOS firewall so phones can connect
  directly.

### 5. Android

```bash
cd android
cp teleport.properties.example teleport.properties              # applicationId, relay URL + key
./gradlew :app:installDebug
```

Builds need JDK 17 or newer. Android Studio's bundled JBR works:
`JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`.

### 6. Windows

The app needs the .NET 9 SDK. It reads its relay settings from
`windows/Teleport.Windows/relay.json`, which is git-ignored:

```json
{ "relayUrl": "https://<your-worker>.workers.dev", "relayKey": "<relay key>" }
```

**On the PC:**

```bash
dotnet run --project windows/Teleport.Windows
```

**From the Mac, over SSH:**

1. Set up OpenSSH Server on the PC.
2. Add a `Host win` entry to `~/.ssh/config`.
3. Run `tools/win sync`. It copies the code to the PC and writes `relay.json`
   from `ios/Config/Teleport.xcconfig`.
4. Use the other commands: `tools/win build | test | run | stop | logs | shot`.

Phones connect directly only on a **Private** network. Allow Teleport through
Windows Firewall on private networks: if you cancelled the firewall prompt,
Windows saved a Block rule that stops phones connecting. On a network you trust,
run this in PowerShell as Administrator, with the path to your built
`Teleport.exe`:

```powershell
Get-NetFirewallRule -DisplayName teleport.exe | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "Teleport" -Direction Inbound -Action Allow -Profile Private -Program "<path to Teleport.exe>"
Set-NetConnectionProfile -InterfaceAlias Wi-Fi -NetworkCategory Private
```

### 7. Pair

1. On one device, show its pairing code: **Pair a device…** on a computer, or
   the pairing section on a phone.
2. On a phone, tap **Scan a code** and scan it.
3. The device showing the code asks you to **Allow** or **Deny**.
4. Once allowed, both devices appear in each other's device picker.

Computers can't scan, so at least one side of every pair is a phone.

## Known limits

- **Very large folders:** a folder of more than about 15,000 items doesn't list.
  It's over the relay's 1 MiB message limit, and listings aren't paged yet.
- **Streaming away from home:** off your home network, streaming goes through the
  relay, so it's limited by your home internet's upload speed.
- **Firebase Android deprecations:** `FirebaseMessaging.token` and `onNewToken`
  show as deprecated with BOM 35.2. Move to the replacement API.
