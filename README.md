# JARVIS for iPhone

The iPhone app for JARVIS on your PC. iPhone only. Deployment target iOS 26; written for iOS 27.

> **Status: UNCOMPILED.** Written on a Windows PC, which cannot run Xcode or the iOS SDK. The PC side it talks
> to is built, unit-tested and deployed; this app has not been built or run. Expect to fix a handful of compile
> errors the first time you open it in Xcode. The crypto it depends on has a built-in self-test (Settings ›
> Encryption self-test) against values the PC computed.

## What it does

- **Pairs** with your PC over home Wi-Fi: finds it by Bonjour (or you type its address), you enter the code the PC
  shows, both screens show the same six digits, you say yes on the PC.
- **Ask JARVIS** by typing or by voice. Answers come back as text and are spoken.
- **Wake word**: switch on *Listen for "Jarvis"* and say "Jarvis, …". Recognition runs on the iPhone
  (on-device only); nothing is sent until it hears "Jarvis" and a request, and then only to your PC. With the
  `audio` background mode it keeps listening with the app in the background or the phone locked, while the
  orange microphone dot shows.
- **Security Protocol**: live status (learning, armed, challenge with countdown and attempts), Arm, Test,
  Initiate, Lock PC, and Stand down.
- **Challenge alerts**: when someone is challenged at your PC, a notification with *It's me (Face ID)* and
  *Not me - lock the PC*. "It's me" answers the challenge only after Face ID.
- **Siri / Shortcuts / Action button**: "Ask JARVIS", "Lock my PC with JARVIS", "JARVIS security status",
  "Initiate security protocol with JARVIS".

## Security model

- Every connection: fresh P-256 key exchange, the PC proves its pinned key, the phone proves its Secure Enclave
  identity key, everything after that is AES-256-GCM with ordered counters. Full spec:
  `F:\J.A.R.V.I.S\docs\MOBILE-BRIDGE-V2.md`.
- Standing the protocol down and approving a challenge need a second signature from an approval key that the
  Secure Enclave uses only after Face ID (`biometryCurrentSet`). A thief with your unlocked phone cannot do either.
- Nothing leaves your home network. No accounts, no cloud, no push server.

## Limits (by design, or by iOS)

- Alerts arrive only while the app is connected: on screen, or in the background while the wake word is on. Alerts
  with the app fully closed would need Apple Push Notifications and an internet-facing relay; not included.
- Away from home Wi-Fi the app cannot reach the PC (no relay). A VPN to your home network (e.g. Tailscale) works
  if you type the PC's VPN address when pairing.
- iOS may stop background listening during calls, Siri, or other apps' recording; it restarts when they end.
- JARVIS also answers out loud on the PC when you ask from the phone.

## Build it (on a Mac)

1. Install Xcode 26 or later, and XcodeGen: `brew install xcodegen`.
2. Copy this folder to the Mac, then in it: `xcodegen generate`, and open `JARVIS.xcodeproj`.
3. Target JARVIS › Signing & Capabilities: choose your team. (A free Apple ID works for your own phone;
   the app then needs re-installing every 7 days.) Change the bundle id if `uk.jarvis.phone` is taken.
4. Plug in the iPhone, enable Developer Mode on it (Settings › Privacy & Security), Run.
5. First run: allow Local Network, Notifications; allow Microphone and Speech Recognition when you turn on the
   wake word.

No Mac? A GitHub Actions `macos` runner can build it, but it cannot sign for your phone without your Apple
developer certificate.

## On the PC

JARVIS › Settings › iPhone: switch on *Let the iPhone app connect* (allow JARVIS through Windows Firewall on
private networks when asked), press *Pair an iPhone*, and approve when the six digits match.

## Layout

```
project.yml                 XcodeGen project (iPhone only, iOS 26+)
JARVIS/Info.plist           permissions, Bonjour service, background audio
JARVIS/App/                 app entry, model, notifications
JARVIS/Bridge/              protocol v2: crypto (+ self-test), Secure Enclave keys, client, discovery
JARVIS/Voice/               wake word listener, speech
JARVIS/Views/               HUD theme, pairing, home/chat, security, settings
JARVIS/Intents/             Siri and Shortcuts
```
