# Keepresso Mobile

An unofficial **Keespresso** Android companion and macOS helper for [Keepresso](https://github.com/gyorgysh/keepresso).

The companion is being built around secure nearby Bluetooth, live Mac/session status, explicit trigger refresh, hourly reminders and acknowledged controls. The official Keepresso app remains unmodified.

## Project status

Initial implementation. See [requirements](docs/requirements.md), [design](docs/superpowers/specs/2026-10-23-companion-design.md) and [wire protocol](docs/protocol.md). Hardware pairing, closed-lid/background operation and real power commands require device acceptance tests; a successful build is not proof of those behaviours.

The initial transport is Bluetooth Low Energy. Internet transport is optional future work, with no Tailscale dependency and no server deployed by this project yet.

## Layout

- `android/`: Kotlin/Jetpack Compose app and JVM-testable protocol core.
- `macos/`: Swift package, menu-bar helper, status adapter and bounded KeepressoCore observer.
- `shared/`: wire contract, deterministic interoperability vectors and original Keepresso artwork.
- `docs/`: agreed requirements, design, build and acceptance notes.

## Privacy and control

Only a phone authorized locally on the Mac may receive private status or control it. Bluetooth discovery is not authorization. Device secrets stay in platform credential stores; expired, replayed and duplicate mutations are rejected. A disconnected Mac is shown as Unreachable; wake is outside scope.

## License and attribution

GPL-3.0. KeepressoCore and the original Keepresso artwork are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This companion is not an official Keepresso release.
