# JARVIS for iPhone

The iPhone app for JARVIS on your PC. iPhone only, portrait, dark. Builds for iOS 18 and later (written on
iOS 27); Xcode 16 or later.

> **Status: first build compiled and ran on 2026-09-18 (GitHub Actions); the voice, circle, face and live view added
> the same day have NOT been compiled yet.**
>
> **Earlier status: UNCOMPILED.** Written on a Windows PC, which cannot run Xcode or the iOS SDK. The PC side it talks to
> is built, unit-tested and deployed; this app has never been built or run. Expect to fix a few compile errors the
> first time. Everything that could be checked without a compiler has been: the Xcode project, the Info.plist, the
> asset catalogue, and - the part that has to be exactly right - the encryption, which has tests against values the
> PC computed (Cmd-U, and Settings › Encryption self-test on the phone).

## Open it

Double-click `JARVIS.xcodeproj`. That project is checked in, so nothing needs installing first.

1. Target JARVIS › Signing & Capabilities › Team: choose your Apple ID. (A free account works for your own phone;
   the app then needs reinstalling every 7 days.) Change the bundle id if `uk.jarvis.phone` is taken.
2. Plug the iPhone in, turn on Developer Mode on it (Settings › Privacy & Security), press Run.
3. Cmd-U runs the encryption tests on the Simulator or the phone.

`project.yml` is the same project as a recipe, for when you would rather generate it: `brew install xcodegen`,
then `xcodegen generate`. Use one or the other - if you run XcodeGen it overwrites `JARVIS.xcodeproj`.

First run on the phone: allow Local Network and Notifications; Microphone and Speech Recognition are asked for
when you first switch the wake word on.

## On the PC

JARVIS › Settings › iPhone: switch on *Let the iPhone app connect* (allow JARVIS through Windows Firewall on
private networks when asked), press *Pair an iPhone*, and approve when the six digits match the phone's.

## What it does

- **Pairs** over home Wi-Fi: finds the PC by Bonjour or you type its address, you enter the code the PC shows,
  both screens show the same six digits, you say yes on the PC.
- **Ask JARVIS** by typing or by voice; answers come back as text and are spoken in **JARVIS's own voice** - the
  PC renders each answer with the same Piper voice it speaks with and sends the audio (Settings › Voice ›
  JARVIS's own voice; the iPhone's voice is the fallback).
- **The circle and the face**, both from the PC's HUD and both reacting: the circle is the HUD's core (rings, sweep,
  iris, a disc that swells with the voice); the face is the HUD's holographic head - the same mesh
  (`Resources/head-mesh.json`, written by `SpeechDiag head-mesh`), the same animator, and lips driven by the mouth
  schedule the PC sends with the voice. Both follow the state: listening, thinking, speaking, asleep offline, red
  for a security challenge. Tap to switch; Settings › Display chooses Circle, Face or Off and turns expressions off.
- **Live view of the PC** (PC tab): pick a display, Face ID, and watch it at about 5 frames a second. Pinch to zoom,
  drag, double-tap to reset, Sideways to fill the screen. Watching only.
- **Wake word**: switch on *Listen for "Jarvis"* and say "Jarvis, …". Recognition runs on the iPhone, on-device
  only; nothing is sent until it hears the name and a request, and then only to your PC. With the `audio`
  background mode it keeps listening with the app in the background or the phone locked, while the orange
  microphone dot shows.
- **Security Protocol**: live status (learning, armed, challenge with countdown and attempts), Arm, Test,
  Initiate, Lock PC, Stand down.
- **Challenge alerts**: when someone is challenged at your PC, a notification with *It's me (Face ID)* and
  *Not me - lock the PC*.
- **Siri, Shortcuts, Action button**: "Ask JARVIS", "Lock my PC with JARVIS", "JARVIS security status",
  "Initiate security protocol with JARVIS".

## Security model

- Every connection: a fresh P-256 key exchange, the PC proves the key this phone pinned at pairing, the phone
  proves a Secure Enclave identity key, and everything after that is AES-256-GCM with ordered counters. Full
  specification: `docs/MOBILE-BRIDGE-V2.md` in the JARVIS repository.
- Standing the protocol down and answering a challenge need a second signature from an approval key the Secure
  Enclave uses only after Face ID, and which dies if Face ID enrolment changes. A thief with your unlocked phone
  cannot do either.
- Nothing leaves your home network. No accounts, no cloud, no push server. The keys never leave the Secure
  Enclave, and what is in the Keychain is device-bound and never synced.

## Limits (by design, or by iOS)

- Alerts arrive only while the app is connected: on screen, or in the background while the wake word is on.
  Alerts with the app fully closed would need Apple Push Notifications and an internet-facing relay.
- Away from home Wi-Fi the app cannot reach the PC. A VPN back to your home network works if you type the PC's
  VPN address when pairing.
- iOS stops background listening during calls, Siri, and other apps' recording; it restarts when they end.
- JARVIS also answers out loud on the PC when you ask from the phone.

## Layout

```
JARVIS.xcodeproj            the project, checked in (Xcode 16+ synchronised folders)
project.yml                 the same project as an XcodeGen recipe
JARVIS/Info.plist           permissions, Bonjour service, background audio
JARVIS/App/                 app entry, model, notifications
JARVIS/Bridge/              protocol v2: crypto (+ self-test), Secure Enclave keys, client, discovery
JARVIS/Voice/               wake word listener, speech
JARVIS/Views/               HUD theme, pairing, home/chat, security, settings
JARVIS/Intents/             Siri and Shortcuts
JARVIS/Resources/           app icon and accent colour
JARVISTests/                encryption tests against the PC's published vectors
```
