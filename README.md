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
- **Works away from home.** With Tailscale on the PC and on this iPhone, the app reaches JARVIS from mobile data
  or any Wi-Fi - and there is nothing to type: connect once at home and the PC hands over every address it has.
  Everything stays encrypted end to end exactly as at home, and the PC still has to prove it is the PC this phone
  paired with, so moving between networks never means pairing again.
- **Wakes the PC while it is asleep.** Deliberately separate from the bridge, which cannot help with a machine
  that is off: from home the phone broadcasts on the local network, from outside it sends to a host you set and
  your router forwards it inwards. A sent packet is a wake request and never a woken PC - the app says ONLINE when
  JARVIS answers, not when the packet left. Say "JARVIS, wake my PC", press the button, or ask Siri.
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
- **Smart home** (Home tab): the house's lights and switches - today the Bedroom Light, a SwitchBot Bot on the
  rocker - one tile per device, grouped by room. ON and OFF switch it through the PC, UPDATING shows while the
  command is out, and "On (unconfirmed)" means the command was accepted but the device has not yet said so. A
  change made anywhere - the PC's HUD, the voice, another phone - is pushed here as it happens. The phone never
  holds a SwitchBot token, secret or device id: it asks the PC, and the PC's Device Service talks to SwitchBot.
  So with the PC off nothing can be switched from here, and the tile says so; wake the PC first. The PC side,
  including setting up the hardware, is `docs/SMART-HOME-AND-SWITCHBOT.md` in the J.A.R.V.I.S repository.
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
- No accounts, no cloud, no push server, and nothing readable by anybody in between. Away from home the traffic
  goes over your own Tailscale network, which carries the bytes and cannot read them - the encryption and the
  pinned PC identity are the same wherever you are. The keys never leave the Secure Enclave, and what is in the
  Keychain is device-bound and never synced.
- Wake-on-LAN is the one thing here with no cryptography in it, because the protocol has none: a magic packet
  carries no secret and proves nothing about who sent it. That is exactly why the only thing it may do is switch a
  machine on. If you forward a port for it, the worst anybody who finds that port can do is turn your PC on.

## Limits (by design, or by iOS)

- Alerts arrive only while the app is connected: on screen, or in the background while the wake word is on.
  Alerts with the app fully closed would need Apple Push Notifications and an internet-facing relay.
- Wake-on-LAN needs a **wired** card. Over Wi-Fi it needs the card, the driver and the access point all to agree
  about it and usually does not work, so the app does not offer it: a button that fails silently is worse than no
  button. Waking from outside the house also needs one rule on your router - see Settings › Waking.
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
