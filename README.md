# Keepresso Mobile

An unofficial **Keespresso** Android companion and macOS helper for [Keepresso](https://github.com/gyorgysh/keepresso).

The companion is being built around secure nearby Bluetooth, live Mac/session status, explicit trigger refresh, hourly reminders and acknowledged controls. The official Keepresso app remains unmodified.

## Project status

First development implementation. Start with [build and pairing instructions](docs/BUILDING.md), [implemented features and limitations](docs/IMPLEMENTATION.md), and the [device acceptance checklist](docs/ACCEPTANCE.md). Hardware pairing, closed-lid/background operation and real power commands require device acceptance tests; a successful build is not proof of those behaviours.

Bluetooth Low Energy is preferred nearby. Optional internet fallback uses an owner-hosted Vercel relay, Firestore and encrypted Firebase push, with the same device pairing. See [self-hosting and free-tier budget](docs/SELF_HOSTING.md) and the [relay contract](docs/relay-protocol.md). There is no shared Keespresso server or Tailscale dependency. Deployed service checks and actual-phone acceptance are separate from source/build tests.

The operator guides cover [fresh Vercel/Firebase deployment](docs/SELF_HOSTING.md), [quota email alerts](docs/QUOTA_ALERTS.md), and [credential reset or rebuilding the setup](docs/RECOVERY.md). Recovery does not depend on retaining the original setup text file.

The approved [requirements](docs/requirements.md), [design](docs/superpowers/specs/2026-10-23-companion-design.md) and [wire protocol](docs/protocol.md) describe the target and the shared contract. In this build safe remote sleep and Celsius readings are unavailable; Pause/Resume depends on a uniquely exposed native Accessibility control. See the status document before relying on reminders or controls.

## Layout

- `android/`: Kotlin/Jetpack Compose app and JVM-testable protocol core.
- `macos/`: Swift package, menu-bar helper, status adapter and bounded KeepressoCore observer.
- `relay/`: encrypted-mailbox API, Firestore adapter and Android push sender for your own Vercel/Firebase accounts.
- `shared/`: wire contract, deterministic interoperability vectors and original Keepresso artwork.
- `docs/`: agreed requirements, design, build and acceptance notes.

## Privacy and control

Only a phone authorized locally on the Mac may receive private status or control it. Bluetooth discovery is not authorization. Device secrets stay in platform credential stores; expired, replayed and duplicate mutations are rejected. A disconnected Mac is shown as Unreachable; wake is outside scope.

## License and attribution

GPL-3.0. KeepressoCore and the original Keepresso artwork are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This companion is not an official Keepresso release.
