# Nearby v2 and private credentials implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Independent components may use the dispatching-parallel-agents skill after the shared contract is fixed.

**Goal:** Prepare prompt-free local credential storage and reliable phone-advertised nearby transport, retaining existing pairing and Internet fallback.

**Architecture:** Android advertises the v2 GATT service and remains the logical authentication client. Mac connects as central and remains the command server, using unchanged framed/encrypted messages and the durable command journal. A private file becomes authoritative after validated legacy migration.

**Tech Stack:** Swift/Core Bluetooth/POSIX file APIs; Kotlin/Android GATT server/Compose; existing crypto/framing and relay.

**Spec:** docs/superpowers/specs/2026-10-28-tetherbug-comparison.md

## Global Constraints

- Keep official Keepresso/vendor unchanged, no real power commands, no permissions or real Keychain operations from tests.
- Preserve device IDs, keys, relay credentials, revocations, Android package and owner signer.
- No paid Apple setup, plaintext network controls, uncertain-mutation retries or permission bypasses.
- Private directory0700/file0600, current owner, regular bounded64KiB file; invalid data never means unpaired.
- BLE service3101, phone→Mac notify3102, Mac→phone write-with-response3103 under the UUID prefix in the spec; logical crypto/framing v1 unchanged.
- Build/emulator checks now; no owner-device installs, actual migrations or real-device tests until reconnection.

## Review Focus

- Secret file symlink/owner/mode/size failure and crash during write must not expose secrets or erase pairing.
- A restarted/upgraded app with a valid private file must never query Keychain; failed migration cannot authorize an empty fallback.
- Late disconnect/write/notification callbacks and a second unauthenticated central must not affect a fresh authorized session.
- Losing nearby while a mutation is pending must preserve uncertainty and never replay it over Internet.
- Legacy app updates, denied advertising permission and absent adapters must retain pairing and useful Internet fallback.

---

### Task 1: Private credentials and migration

**Files:** create CompanionCore private-file store and focused tests; modify macos/Sources/KeepressoMac/CredentialStore.swift; update SavedConnectionFailure only if a specific storage failure needs it. Do not edit App.swift, BluetoothServer.swift or version scripts.

**Interfaces:** preserve loadSaved(allowInteraction:Bool) throws -> SavedAuthorization, save([AuthorizedDevice]), saveRelay(RelayConfiguration). Default file path and validation are in the spec. Inject the legacy reader for tests; valid file means zero legacy calls.

- [ ] Write failing tests for round-trip/migration retained keys, no legacy reads after restart, insecure mode/symlink/oversize/corrupt rejection, failed write preserving old data, and partial-device/relay updates.
- [ ] Run focused tests and observe intended failures.
- [ ] Implement bounded owner-only atomic storage and legacy-read migration; preserve old Keychain records, use only fixtures.
- [ ] Run focused and full Swift suite; review and commit this task.

### Task 2: Mac central transport

**Files:** replace macos/Sources/KeepressoMac/BluetoothServer.swift physical implementation; add platform-neutral connection/queue policy and tests in CompanionCore as necessary. Do not edit CredentialStore, App.swift, Android, shared constants or version scripts.

**Interfaces:** preserve BluetoothServer façade start/stop/tick/authenticatedDevices/approvePending/denyPending/revoke/sendRelayConfiguration/sendEvent/broadcast and its model interactions. Consume NearbyGattV2 string constants. Handle notify3102 and write3103 as in spec; reuse existing ServerHandshake/SealedChannel/FrameDecoder and model.handle without bypassing authority.

- [ ] Write failing tests for discovery/subscription readiness, queue acknowledgement/backpressure, timeouts, stale generations and revoked/disconnected authority.
- [ ] Observe failures, then implement CBCentralManager/CBPeripheral delegates with bounded queues, connection retry and lifecycle cleanup.
- [ ] Preserve owner approval, legacy device list, fresh sessions, command outcomes and event/relay delivery.
- [ ] Run relevant/full Swift tests; review and commit this task.

### Task 3: Android peripheral transport

**Files:** create BlePeripheral.kt; integrate NearbyService.kt, MainActivity.kt permission selection and AndroidManifest.xml; add pure/core state tests and focused Android transport tests as needed. Do not edit version/signing Gradle inputs, shared constants, VirtualMacPeerTest.kt or production credentials.

**Interfaces:** BlePeripheral(Context,state:(String)->Unit,subscribed:()->Unit,record:(String)->Unit,disconnected:()->Unit) exposes start(resetCandidates:Boolean=false), close(reason:String?), send(String), authenticated(). Service calls remain compatible. Consume NearbyGattV2 constants. Notify3102 has CCCD; write3103 receives Mac messages. Android is still ClientSession. Add BLUETOOTH_ADVERTISE to permission gating; missing permissions retain relay and pairing.

- [ ] Write failing tests for one subscribed event, fragmented notify/write delivery, queue bounds, wrong-central/stale callbacks and advertise-permission denial preserving authorization.
- [ ] Observe failures, then implement GATT server/advertiser with public APIs and no bond requirement; no hardware or permission grants on the real phone.
- [ ] Run core tests, relevant instrumentation compilation, lint and APK build with empty/public fixture configuration.
- [ ] Review and commit this task.

### Task 4: Integration, emulator acceptance and packages

**Files:** root-owned protocol docs, shared/nearby-v2.json and matching core constants, emulator VirtualMacPeerTest fixture, any integration tests, version/config packaging and recovery docs. Integrate reviewed component commits.

**Interfaces:** fixture Mac is a central but logical server, using the same paired vectors and fresh crypto. Owner Android remains0.4.7 until reconnection; final APK must be0.5.0/code5000 and signer166dd4…2395d. Mac0.5.0/build13 remains a ZIP/staged self-check, never normal launch.

- [ ] Fix contract constants first; preflight-check all shared interfaces and component ownership, then dispatch isolated worktrees.
- [ ] Integrate component changes and adapt synthetic Mac/phone emulator GATT tests. Test new pairing, retained authorization/reconnect, slow response plus one queued command, invalid auth and synthetic duplicate effects.
- [ ] Run Swift, JVM core, Android lint/build/instrumentation and two-emulator GATT scenarios; preserve uncertainty/route-handover tests. Test migration with fixture secrets only.
- [ ] Obtain task reviews and one fresh whole-change review; fix confirmed important findings with RED→GREEN tests.
- [ ] Package Mac ZIP and retained-signer Android APK with Firebase client configuration, verify versions/signatures and self-check, document private-file recovery and one-time owner migration. Remove loose staged app and disposable fixtures.
- [ ] Report artifacts and verified emulator boundaries. Wait for phone reconnection before sideloading and physical co-existence/lid tests.
