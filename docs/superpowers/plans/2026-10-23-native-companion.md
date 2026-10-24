# Native Companion Implementation Plan

> **For agentic workers:** Use the platform-specific plan below. Native platform implementations can run independently against docs/protocol.md; one integration/security review checks the combined branch.

**Goal:** Build an installable Android app and macOS helper implementing the approved nearby Keepresso companion.

**Architecture:** Swift peripheral and Kotlin central communicate with the authenticated/encrypted shared record protocol. Ordinary status uses native cheap readings; trigger assessment reuses pinned KeepressoCore only during a bounded refresh. OS adapters preserve unavailable/unknown state and never synthesize success.

**Tech Stack:** Swift 5.9+/macOS 14+, CoreBluetooth, CryptoKit, SwiftUI, Keychain; Kotlin 2.1.20, Compose, Android API 28+ / compile+target 35, AGP 8.9.2, Gradle 8.11.1, JDK 17.

**Spec:** ../specs/2026-10-23-companion-design.md and ../../requirements.md; wire contract ../../protocol.md.

## Global constraints

- App name Keepresso; private repository keepresso-mobile; original artwork and copper theme.
- Official Keepresso stays unmodified; no Tailscale, remote wake or permanent duplicate detector.
- Trigger timestamp is Triggers checked at… directly below Active triggers, before rows.
- Secure authorized devices only; app-level authentication over unbonded BLE; no plaintext private status.
- Bounded 5-second refresh, input uncertainty explicit. Native manual semantics remain unchanged.
- Hourly reminder, OK, 6-hour routine-only snooze; one stopped-but-awake warning after 300 seconds.
- No real power mutations, permission grants or login-item enabling during tests.

## Review focus

- A partial or oversized BLE frame must not cause unbounded memory or mix messages between peers.
- Disconnection at the command/ack boundary must leave a mutation uncertain, never automatically retry it.
- Restart/revocation/expired pairing must not restore authorization or replay a power operation.
- Unknown sensor, unsupported preferences or expired status must not become a misleading safe/default state.
- A stopped-session warning must be canceled by observed sleep or renewed activity, including after restart.

### Task 1: shared contract, test vectors and repository

Files: docs/protocol.md, shared/vectors.json, scripts/generate-vectors.mjs, shared/upstream.json, AGENTS.md, README.md, LICENSE, THIRD_PARTY_NOTICES.md.

- [ ] Publish a deterministic reference fixture generated independently with Node's crypto; real keys never enter fixtures.
- [ ] Verify and record private repository visibility and pinned vendored source digests.
- [ ] Commit architecture/requirements and the fixed wire contract before platform implementations.

### Task 2: Swift native helper

Files: macos/Package.swift; macos/Sources/CompanionCore (models, crypto, framing, pairing, command journal, reminders); macos/Sources/KeepressoMac (status, BLE, UI, native adapters); macos/ThirdParty/KeepressoCore/Adapters; macos/Tests; macos/scripts/build-app.sh.

Interfaces: consumes docs/protocol.md and shared/vectors.json; produces executable KeepressoMac, .app build script, native status/command/trigger/notification protocol server.

- [ ] Write security/framing/journal/reminder tests before their implementations; record expected RED and GREEN results.
- [ ] Implement genuine crypto over common vectors, exact counter checks and strict bounded framing.
- [ ] Implement expiring locally approved pairing and secure revocation; no real credentials in tests.
- [ ] Implement durable reserve-before-execute journal; use fakes for power commands and crash uncertainty tests.
- [ ] Implement live native status, strict settings decode, capability checks and explicit unavailable controls.
- [ ] Implement public manual URL actions plus safe bounded acknowledgement, constrained accessibility controls where possible; never operate real power state during verification.
- [ ] Implement read-only hook copies and a 5-second observer lifecycle with timestamps/unknown handling.
- [ ] Implement persistent reminder scheduling and BLE delivery; no obsolete warnings after sleep/new sessions.
- [ ] Add native pairing/settings menu and original app icon; build runnable .app with appropriate usage descriptions.
- [ ] Verify swift test and packaged helper --self-check without opening Bluetooth/power/permission prompts.

### Task 3: Android native app

Files: android/core (protocol/security/models/tests); android/app (Compose screens, BLE service, credential store, notification receiver); Gradle wrapper/config.

Interfaces: same contract/fixtures; produces JVM-testable protocol core and app-debug.apk.

- [ ] Write core crypto/framing/freshness tests first, record RED then GREEN. Validate bad tag, wrong peer/nonces, replay, overlong/fragmented records.
- [ ] Implement QR invitation parser, proof/handshake state, Keystore-wrapped credentials, no backups.
- [ ] Implement serialized GATT subscription/writes with segmentation, backpressure, reconnect authentication and no queued mutation replay.
- [ ] Match approved screen including divider, original icons, trigger timestamp/Refresh, duration stepper and controls with confirmed acknowledgements.
- [ ] Separate general status updates from bounded trigger refresh. Preserve last-known state when unreachable.
- [ ] Implement foreground connected-device service and notification actions OK/Snooze/Open; handle permission denial and unavailable BLE.
- [ ] Implement Activity and Settings, phone revocation/reset and clear connection state.
- [ ] Verify JVM tests, Android lint and debug APK build on a configured SDK runner; do not claim physical BLE success from those checks.

### Task 4: integration, builds and review

Files: .github/workflows/build.yml; scripts/verify-upstream.py; docs/BUILDING.md; docs/ACCEPTANCE.md.

- [ ] Validate common crypto vectors against both implementations; validate request/response examples and snapshots across platforms.
- [ ] Run Swift tests and Android unit/lint/build checks. Upload .app ZIP and APK as private CI artifacts.
- [ ] Fresh review of actual combined code: protocol security, unsafe control paths, reconnect, status truthfulness and reminder lifecycle.
- [ ] Resolve important findings with regression tests and run affected/full checks once more.
- [ ] Push the working branch and create a draft PR; keep visibility private and hardware acceptance explicitly pending.
