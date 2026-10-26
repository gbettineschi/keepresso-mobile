# Keepresso companion design

The owner approved the evolving Android mock and requested implementation on 23 October 2026. The binding product requirements are in ../../requirements.md. Routine implementation choices below are builder decisions, not new user preferences.

## Intent

Let an authorized Android phone inspect and control a nearby awake Mac running the stock Keepresso app, and receive reminders that reduce the risk of leaving it awake unintentionally. Preserve normal official app updates.

## Approach chosen

Native Kotlin/Compose Android app and Swift macOS background companion with a settings window (see the later approved background design). Bluetooth LE is the first transport: Mac peripheral, Android central, no OS bonding requested. QR-based application authorization is mandatory. A bounded shared-engine observer handles the missing per-trigger export. Ordinary status and reminders do not depend on that observer.

Alternatives considered: a full Keepresso fork provides native private state but creates update/signing work; an upstream status export is cleaner but unavailable today; a separate detector implementation duplicates logic. Reusing pinned KeepressoCore with explicit preview freshness was selected by the owner. Internet relay is optional later work; it is not a dependency for nearby operation.

## Components

1. Shared versioned JSON protocol over length-prefixed BLE records, with common deterministic crypto vectors.
2. Android app: pairing/QR entry, permission onboarding, secure credential storage, serialized GATT operations, authenticated session, agreed dashboard, commands and confirmation sheets, notifications with OK/Snooze 6 hours, Activity and Settings.
3. Mac helper: local pairing approval and revocation UI, Keychain credentials, encrypted BLE service, cheap status sampler, durable mutation journal, reminder state machine and command adapters.
4. Trigger observer: run for up to five seconds per refresh, reuse unmodified KeepressoCore, read saved rules strictly, isolate its hook cleanup through temporary copies, return current evidence and uncertainty. No permanent duplicate engine. No automatic power holds.
5. Build automation: Swift tests and .app bundle; Android unit tests, lint and APK. Shared test vectors must agree across platforms.

## Security and pairing

Only a local Mac action opens a five-minute pairing window. It displays a QR invitation carrying a random 256-bit secret, Mac UUID and expiry. The phone proves possession without transmitting that secret over Bluetooth. The Mac owner approves the named pending phone once; approval derives and stores a unique per-phone key. Reusing or expired invitations is rejected. Revocation immediately drops sessions.

Subsequent sessions authenticate both sides using fresh random nonces, HMAC-SHA256 and domain-separated proofs. HKDF-SHA256 derives separate AES-256-GCM keys for each direction. Sequence-derived nonces and strict receive counters reject replay. See ../../protocol.md for exact bytes. This is a new protocol implementation requiring adversarial tests and review, not a claim of independent security audit.

Secrets: macOS Keychain; Android Keystore-wrapped credential bytes with backup disabled. No plaintext credentials in logs, clipboard by default or repository. Pairing QR material is shown only while pairing is armed.

## State and commands

Treat BLE link plus authenticated fresh response as reachable. Missing, stale or failed readings remain unknown/last-known; no inference of sleep from disconnection. macOS readings provide lock, display, lid, battery and thermal state; unsupported temperatures stay unavailable. Native status.json supplies app/session activity, endsAt and trigger enabled/paused flags. Do not silently decode unsupported preferences as defaults.

Every request has a UUID, issuedAt and expiresAt with a maximum 30-second validity. The ready message supplies Mac time for client clock offset. Mutation IDs are durably reserved before execution. Same ID with a different body or owner is rejected. An in-flight operation interrupted by crash stays uncertain; never automatically execute it again. Mutations are not queued across reconnects.

Native public URL commands implement manual start and stop, with observed status acknowledgement. Remote Pause/Resume requires a constrained accessibility adapter because the stock public API lacks those actions; absence of permission or an unambiguous control yields unavailable, never a guessed click. Starting a manual session preserves stock pause semantics. Sleep must release/stop relevant holds and use the native safe path; if that path cannot be established, report unavailable. Development tests never sleep the real Mac.

## UX

Match the approved v8 mock. App name Keepresso; original icon/cups and copper palette. Status rows Lock/Display/Lid, separator, Battery/Temperature. Brewing time means remaining time only. Active triggers has a small Triggers checked at… · Refresh row directly below its title; no Independent preview/sample-data line in the product. Refresh is a snapshot in both manual and auto mode. All controls disable when unreachable. A real result updates its own timestamp; failed reads do not.

Manual duration uses 15-minute +/- steps and inline Start, or Stop manual session. Resume warns about immediate handover. Sleep confirms consequences. No wake feature or Live badge.

## Reminders

Hourly while native Keepresso is actively holding awake: include end time or no automatic end. OK preserves next hour; Snooze 6 hours affects routine alerts only. Warn once five minutes after a session ends if Mac stayed awake; cancel on a new session or observed sleep. Thermal/battery/sleep-failure warnings bypass routine snooze. Persist schedule/snooze state across helper restarts. No reminder requires the duplicate engine.

For Bluetooth background delivery Android must keep a user-visible connected-device foreground service while enabled. Explicitly surface loss of range; no claims of internet delivery. Real Android screen-off/Doze and closed-lid tests remain acceptance work.

## Scope and acceptance

Implement both native applications and the secure nearby path now. Build the shared protocol so an internet relay can be added without changing phone authorization. Do not deploy a relay, enable login launch, grant OS permissions or execute live power mutations during development.

Automated acceptance: crypto interoperability/tamper/wrong-peer/replay/reconnect tests; frame fragmentation and bounded inputs; pair expiry/reuse/revocation; command expiry/dedup/crash uncertainty; reminder snooze and stale-warning cancellation; status unknown/freshness interpretation; strict preferences; bounded observer teardown; platform builds.

Hardware acceptance: owner-approved QR pairing, Android background notifications, BLE loss/reconnect, Mac closed lid, native manual/trigger handover and explicit sleep. Report these as unverified until performed. The plan must not treat fixtures, compilation or synthetic prompts as hardware acceptance.
