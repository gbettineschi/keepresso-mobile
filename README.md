# Keepresso Mobile

An unofficial Android app and macOS companion for [Keepresso](https://github.com/gyorgysh/keepresso). See your Mac’s status, check its configured triggers, control supported sessions and receive reminders. Keepresso Mobile runs alongside the original app. I built this companion with AI for personal use and share it as is.

## How it connects

- **Nearby:** Bluetooth, with one-time phone approval on the Mac.
- **Away:** iroh connects over the Internet, directly where possible and through an encrypted public relay otherwise. No common Wi-Fi network or owner-run server is needed.
- **Background notifications:** the Mac sends encrypted alerts through your own free Firebase Cloud Messaging project. Its private sender key stays on the Mac.

The same pairing authorizes both connections. There is no shared Keepresso backend, Vercel account, Firestore database, Cloud Functions or Tailscale requirement for the new setup. Internet uses iroh’s public discovery/relay infrastructure; background push uses Google Play services and Firebase.

## Install the preview

1. Install [Keepresso](https://github.com/gyorgysh/keepresso/releases) on your Mac.
2. Download the Mac ZIP and Android APK from [GitHub Releases](https://github.com/gbettineschi/keepresso-mobile/releases). On Android, you can also add this repository in Obtainium and enable **Include prereleases**.
3. Open Keepresso Mobile on both devices, scan the Mac’s pairing code, and approve the phone on the Mac. [Install and pair](docs/BUILDING.md)
4. For background notifications, [set up your own Firebase project](docs/SELF_HOSTING.md). Bluetooth and Internet status and controls work without Firebase.

The Mac helper requires **Apple silicon and macOS 14.5+**. Android requires **Android 9+**. Background notifications require Google Play services. The Mac preview is not notarized and may require approval in System Settings on first open. Public previews through v0.6.12 are ad-hoc; the new release pipeline uses a persistent project signing certificate, with a one-time permission transition. [Mac signing and troubleshooting](docs/MAC_SIGNING.md)

Stock Keepresso supports status, trigger checks, and the controls shown as available in the app. The new unattended, closed-lid, and critical alarm flows and the new **Sleep now** path depend on status fields from an experimental native Keepresso build. [Preview compatibility and verification](docs/releases/0.6.10.md)

## Privacy and control

Only a phone approved locally can read private status or issue controls. Discovery and an iroh address do not grant access. Every connection uses the existing authenticated encryption; mutations share a durable duplicate journal and are never replayed automatically after uncertain delivery. A lost connection means **Unreachable**, not proof that the Mac is asleep.

Android secrets are Keystore-wrapped. Mac secrets use validated private files; another program running as your user can read them. The app requests only the access needed for configured features. [Requirements](docs/requirements.md), [wire protocol](docs/protocol.md), [Internet protocol](docs/internet-protocol.md).

## Repository

- `android/`: Kotlin/Compose app and protocol core.
- `macos/`: hidden background companion, settings and bounded trigger observer.
- `shared/`: deterministic public test vectors and Keepresso artwork.
- `relay/`: legacy Vercel/Firestore implementation retained for migration; not required by the new setup.
- `docs/`: setup, recovery, implementation and acceptance records.

GPL-3.0. Attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This is not an official Keepresso release.
