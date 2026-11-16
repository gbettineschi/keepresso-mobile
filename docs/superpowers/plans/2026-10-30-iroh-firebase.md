# iroh and direct Firebase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Ship the approved paired BLE/iroh companion with direct encrypted Firebase notifications, removing Vercel/Firestore from its normal operation.

**Architecture:** Retain the current pairing and shared mutation executor. Authenticated configuration enrolls a persistent iroh address and public Firebase client options; the Mac keeps private sender credentials and registered phone tokens. Existing encrypted event envelopes and Android event claims remain the notification boundary.

**Tech Stack:** Swift, Kotlin/Compose 2.2.21, iroh-ffi 1.2.0, Firebase Android Messaging, FCM HTTP v1, platform cryptography and existing protocol cores.

**Spec:** docs/superpowers/specs/2026-10-30-iroh-firebase-design.md (owner approved in chat, 30 October 2026).

## Global Constraints

- Preserve pair IDs, keys, invitation scheme, bundle/package IDs, credential aliases and retained Android signing identity.
- Keep all 107 pinned Keepresso source files byte-identical. No real power/settings/login-item/permission mutations in automated tests.
- First integration package: Apple silicon and macOS 14.5+; Android minimum OS unchanged. iroh 1.2.0 exactly; Kotlin/Compose plugins 2.2.21.
- BLE preferred; one command path per request; no automatic retry of uncertain mutations. Same durable executor and request fingerprints on all paths.
- Record limit 65,536 bytes, partial frame and handshake deadlines ten seconds, four pending handshakes, eight authenticated sessions, one stream/connection, twenty-second idle limit and fifteen-second authenticated freshness.
- Event envelope at most 3,000 UTF-8 bytes, complete FCM send body at most 4,096 bytes, original event expiry at most 300 seconds, at most 256 pending event/device deliveries.
- Private seed, service account and token registry use independently validated owner-only files. Firebase sender credentials never go to Android or git.
- No billing enablement, Cloud Functions, new wake hold, Tailscale or destructive cloud retirement before replacement acceptance. No release publication without owner instruction.

## Review Focus

- A paired phone receives replacement/malformed metadata: retain authorization and the last valid metadata; never accept unauthenticated enrollment (Tasks 1, 5).
- Sleep/revoke/route change occurs during a native mutation: invalidate the old generation, retain uncertain outcome and execute at most once (Tasks 2, 3, 5).
- The FCM token rotates while an older registration/upload is in flight: newest persisted revision wins, including after process restart (Tasks 1, 6).
- Unicode/large event or delayed retry exceeds the push limit or original expiry: bound complete serialized bytes and never refresh old event validity (Task 4).
- Mac/phone restarts or changes network while lookup/notification setup is incomplete: recover by stable identity without re-pairing, preserve honest unavailable states and no power replay (Tasks 3, 5, 7, 8).

## Verification commands

Swift: swift test --package-path macos. Android core: android/gradlew -p android -PcoreOnly :core:test with the existing JDK 17. App build/lint uses the existing JDK 21 and Android SDK, with explicit toolchain paths. Long outputs go in this plan's ignored workspace. The upstream check is python3 scripts/verify-upstream.py.

### Task 1: Shared enrollment contracts

**Files:** Create CompanionCore/InternetConfiguration.swift, CompanionCore/PushRegistration.swift and Kotlin core/InternetConfiguration.kt; add matching Swift/Kotlin tests; extend core/ClientSession.kt.

**Interfaces:** FirebaseClientConfiguration(projectId, applicationId, apiKey, senderId); InternetConfiguration(version=1, endpointId, firebase?); PushRegistration(projectId, token, revision); PushRegistrationAck(projectId, revision, tokenHash). endpointId is the canonical Base64 encoding of the SDK's 32 raw identity bytes. All model decoders validate lengths/types, sender/application-ID consistency and the exact version. Acknowledgement tokenHash is SHA-256(token UTF-8), canonical Base64. Registry rejects lower revisions and same-revision/different-token writes; exact duplicates are idempotent. Registration is authenticated maintenance, separate from native command execution.

- [ ] Write InternetConfigurationTests and InternetConfigTest: canonical 32-byte endpoint round-trip; reject bad length/noncanonical encoding/version, incomplete or mismatched Firebase options; new encrypted message types accepted only after authentication; legacy pairing fixtures unchanged. PushRegistrationTests assert lower revision cannot replace revision 2, exact duplicate succeeds and conflicting revision 2 fails.
- [ ] Run focused new tests; expected failure for missing contracts.
- [ ] Implement validated models/JSON encoding, encrypted configuration/registration acknowledgement message support and a pure registry transition.
- [ ] Run both complete core suites; expected no failures.
- [ ] Commit shared enrollment contracts.

### Task 2: Transport-independent Mac command session

**Files:** Create CompanionCore/InternetSession.swift and tests; adapt no native code yet.

**Interfaces:** MainActor InternetSession(macId, lookupDevice, authorized, configuration, execute, registerPush, snapshot, now, monotonic). receive(Data) async throws -> Data processes one framed record's contents; close() invalidates all outstanding work. execute consumes the existing CommandRequest/device/raw bytes plus a live authorization closure and returns the response object. Config and push registration use Task 1 models. A fresh successful status response is required before mutations on this session; snapshots accompany existing command responses. Registration bypasses the power executor but still requires current authenticated authorization.

- [ ] Write InternetSessionTests: unknown/wrong-key/replayed input refused; valid status authenticates; mutation before status rejected; two sessions sending one mutation ID reach the shared journal once; revoke/close during a suspended request suppresses late output; push registration cannot execute a power action.
- [ ] Run focused tests; expected failure for missing session.
- [ ] Implement the bounded state machine using ServerHandshake, SealedChannel, existing framing and injected callbacks.
- [ ] Run full Swift suite; expected no failures.
- [ ] Commit server session.

### Task 3: Mac iroh endpoint and lifecycle

**Files:** macos/Package.swift; create KeepressoMac/IrohServer.swift and CompanionCore/PrivateInternetState.swift plus tests; modify CompanionModel.swift and BluetoothServer.swift.

**Interfaces:** IrohServer.start(seed, sessionFactory, stateChanged) async, stop() async and endpointId; persistent seed loads from its own validated file. Use EndpointOptions.protocols with ALPN keepresso-mobile/iroh/1. Each admitted connection owns a Task 2 session and a single bidirectional stream. CompanionModel generates Task 1 config, sends it after BLE authentication and routes iroh commands into the existing handle/executor with lifecycle witnesses.

- [ ] Write PrivateInternetStateTests and admission/lifecycle tests: preserve the seed after reload, refuse symlinks/insecure/corrupt records without touching pairing, close/revoke sessions, cap handshakes and connections, reject excess streams and stale generations.
- [ ] Run focused tests; expected failure for absent storage/admission behavior.
- [ ] Implement hardened independent seed storage and the SDK adapter; pin the tested package, set the approved test-platform floor and wire lifecycle/config publication. No instance may start from unit tests or self-check without an injected fixture.
- [ ] Run full Swift suite, release build and unchanged-upstream check; expected success.
- [ ] Commit Mac endpoint integration.

### Task 4: Direct encrypted FCM sender

**Files:** Create CompanionCore/FirebaseSender.swift, FirebaseSenderStorage.swift, NotificationOutbox.swift and tests; add fake public RSA fixtures under shared fixtures only.

**Interfaces:** FirebaseSenderConfiguration(client: Task 1 config, projectId, clientEmail, privateKey, privateKeyId?); FCMHTTP transport injected for token/send calls; send(envelope, token, now) async -> result. Fixed OAuth and FCM hostnames, firebase.messaging scope, RS256 platform signing, expiry-aware token cache. NotificationOutbox supplies due event/device deliveries, schedules only transient failures with bounded backoff, removes expired/obsolete/revoked events and retains original ciphertext/expiry. Push registry persistence uses Task 1 transitions and independent owner-only storage.

- [ ] Write FirebaseSenderTests and NotificationOutboxTests: public RSA JWT signature/claims; correct fixed destination; reject mismatched projects/arbitrary credential URLs; cache and refresh access token; transient retry versus unregistered token; Unicode/body byte budget; no retry after original 300-second expiry; overlap/revocation and 256-cap behavior.
- [ ] Run focused tests; expected failure for absent sender/outbox.
- [ ] Implement private credential import/validation, signing, OAuth/send transport and durable bounded event scheduling. Do not read real credentials in tests.
- [ ] Run full Swift suite; expected no failures.
- [ ] Commit direct notification sender.

### Task 5: Android iroh routing and metadata persistence

**Files:** Update Android plugins/dependency declarations; create app/IrohConnection.kt and InternetCredentialStore.kt; modify NearbyService.kt, CredentialStore.kt and core route tests.

**Interfaces:** IrohConnection owns an independent ClientSession and coroutine lifetime, exposes authenticated/closed/message callbacks on the main thread, send(rawRequest) and close(). InternetCredentialStore uses the existing Keystore wrapper and binds endpoint/config state to the existing macId/deviceId/key fingerprint. It never changes the existing Credential key. NearbyService retains one pending sender/journal across nearby and iroh and reconciles outcomes through existing operation_status, never replaying the original operation.

- [ ] Write core/Android tests for old credential preservation, tampered/foreign metadata rejection, route precedence, generation changes, quiet-read failure retaining another fresh route, in-flight mutation uncertainty, stale snapshot ordering and stable trigger history.
- [ ] Run new tests; expected failure for absent internet routing/enrollment.
- [ ] Implement native binding loading, stable-identity lookup, encrypted config acceptance, route selection, bounded reconnect and matching response/event handling. Legacy polling is bootstrap only when no iroh enrollment exists; no normal Vercel traffic after enrollment. Preserve UI layout and capability gating.
- [ ] Run full core suite, app lint/build and relevant emulator tests; expected success.
- [ ] Commit Android connection integration.

### Task 6: Android Firebase enrollment and direct event delivery

**Files:** Modify RemoteMessaging.kt; create FirebaseClientSetup.kt and DirectPushRegistrationWorker.kt; add pure enrollment core and tests; extend emulator tests.

**Interfaces:** Runtime Firebase client uses Task 1 options from authenticated metadata; same-project setup is idempotent. A project replacement deliberately replaces SDK configuration and any restart requirement is surfaced. Token callbacks persist current token/revision first; background registration dials the authenticated Mac through Task 5, sends Task 1 registration and records only a matching current acknowledgement. It can retry enrollment after process death but cannot send queued power commands. Direct FCM events use existing RelayCodec/event claims without requiring relay URL/ticket.

- [ ] Write token rotation/race/restart tests and event delivery tests: old acknowledgement never marks a newer token registered; unreachable Mac retains pending registration; project change does not clear pairing; bad/wrong-device/expired/duplicate envelopes cannot notify; same event on BLE and push notifies once.
- [ ] Run focused tests; expected failure for new direct delivery/enrollment.
- [ ] Implement runtime client options, transaction-bound token registration worker and direct encrypted payload reception with current notification channels/actions. Keep old event format acceptance for migration only.
- [ ] Run full core suite and emulator messaging/setup tests with fake SDK/sender; expected success.
- [ ] Commit Android direct push.

### Task 7: Owner setup, migration and documentation

**Files:** Mac CompanionModel.swift/App.swift and new FirebaseSetup.swift; Android settings as needed; README and BUILDING/IMPLEMENTATION/ACCEPTANCE/SELF_HOSTING/RECOVERY/QUOTA_ALERTS/protocol documentation.

**Interfaces:** A single Mac import flow accepts service-account JSON and matching google-services client JSON, validates both before atomic configuration change and publishes only public client options. Notification status distinguishes credential import, token enrollment and actual delivery acceptance. Iroh enablement preserves the owner's saved connection choice. Migration may read legacy config but does not delete pairing or cloud data.

- [ ] Add setup tests for malformed/mismatched imports, cancellation, retry, existing-pair migration, missing-token status and credential replacement without endpoint/key reset. Add a check that normal enrolled operation makes no Vercel/Firestore call.
- [ ] Run new tests; expected failure for missing setup behavior.
- [ ] Implement the focused UI and migration; update all operator guides with no-server setup, key/token/identity recovery, no-billing constraints and exact tested platform support. Keep existing unsupported native capabilities explicit.
- [ ] Run both complete core suites, builds/lint, self-check and upstream digest; expected success.
- [ ] Commit setup and operator documentation.

### Task 8: Cross-platform and owner acceptance

**Files:** Add production-protocol fixtures/instrumentation and emulator runner under scripts/tests; extend docs/ACCEPTANCE.md with results and remaining physical gates. Do not import real keys into fixture tests.

**Interfaces:** A standalone Mac fixture uses Tasks 2–4 with fake readings/native actions; emulator tests use Tasks 5–6 and synthetic authorization. Stable identity is delivered through the same encrypted config path as production, not an injected ticket. Existing test scripts remain explicit about serial/device type.

- [ ] Add regression scenarios for identity-only dial after restart, forced relay, 20 reconnects while another connection stalls, live route changes, concurrent duplicate fake mutations, locked/background notification processing and oversized/expired events.
- [ ] Run them before accepting the implementation; expected failure exposes the actual missing behavior, then correct the owning component and rerun focused plus full suites.
- [ ] Build and verify in-place owner packages with retained identities/signing; configure the owner's Firebase sender privately only after validating the exact existing project. Never echo secrets or enable billing.
- [ ] Perform real read-only status/trigger, direct/relay and locked-phone notification checks when the owner device is connected. The owner performs any requested physical sleep/lid actions. Preserve honest incomplete gates if access is unavailable; continue all independent work.
- [ ] Run a final independent whole-branch security/behavior review, address important findings with RED→GREEN tests, and record release/retirement readiness. Retire exact dedicated legacy resources only after replacement acceptance; never delete the Firebase project or publish an unrequested release.

Execution method: inline implementation in the existing isolated worktree, with one independent whole-branch review. This is the builder's execution choice under the owner's explicit instruction to proceed with implementation, not a second request for permission.
