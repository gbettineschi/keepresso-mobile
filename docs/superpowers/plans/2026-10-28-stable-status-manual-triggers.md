# Stable status and manual triggers implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Independent platform tasks can use dispatching-parallel-agents after this contract is fixed.

**Goal:** Preserve manual trigger results, reliable explicit checks and a steady Android dashboard.
**Architecture:** Mac holds historical assessment separate from check/context metadata; explicit relay read runs asynchronously while telemetry continues; Android owns its manual-result view and stable presentation.
**Tech Stack:** Swift/CoreBluetooth existing relay/worker, Kotlin/Compose existing authenticated routes.
**Spec:** docs/superpowers/specs/2026-10-28-stable-status-manual-triggers-design.md

## Global Constraints
- Same identities/keys/crypto/dedup/15s freshness/30s request validity. No native/vendor, permission, power or real-key operations in tests. No cloud changes.
- Optional triggers.checking/outdated/checkError; manual data never changes through ordinary polling after a committed result. Partial unknown is a completed assessment, not a worker failure.
- Parent12s / child8s / phone25s explicit-check bounds. No automatic evaluation/retry/prewarming.
- Owner installs deferred until validated packages and USB; root owns versions/signing/fixtures/delivery, each implementation worktree isolated.

## Review Focus
- Older telemetry arriving after a valid explicit result must not erase it; an older capture can still carry the matching manual result.
- Actual rule changes versus non-trigger preference rewrites; failure/cancellation/empty-success semantics.
- Long read cannot starve heartbeat or grant mutation authority; duplicate jobs, epoch/revoke/stop cancellation and no late reply.
- UI geometry across connecting/offline/fresh/long Wi-Fi/error/checking states and font scales; full safety meaning accessible.

### Task 1: Mac manual assessment and worker lifecycle
Files: Models.swift optional fields; new CompanionCore assessment-history policy/tests; KeepressoMac/TriggerObserver.swift; CompanionModel.swift only observer/cache calls and refresh outcome; TriggerRefreshOwner.swift cancellation propagation; BoundedWorker.swift parent bound; App.swift only watchdog constant if needed (engine remains8). No RelayCoordinator, Android or versions.
- [ ] RED tests history, failure/partial/empty/config changes/cancellation/startup-bound semantics.
- [ ] Implement canonical rule-set tracking, latched assessment and separate optional metadata, parent12/child8, propagate cancelled caller to worker. No ordinary assessment execution.
- [ ] Run focused/full Swift fixture tests, self-review and signed commit/report.

### Task 2: Nonblocking explicit relay trigger read
Files: CompanionCore/RelayCoordinator.swift + relevant/new relay tests only. Same execute/snapshot API; consumes Task1 cancellation propagation. No model/observer/Models/Android/version edits.
- [ ] RED suspended explicit-check test: next tick must still publish fresh state/poll; duplicate read executes once; cancellation rejects output.
- [ ] Implement bounded per-device read jobs only for refresh_triggers, dedup and lifecycle cleanup. Preserve all mutation/status proof/journal semantics.
- [ ] Relevant/full Swift fixtures, signed commit/report; physical tests root only.

### Task 3: Android stable dashboard and manual view
Files: NearbyService.kt, MainActivity.kt, focused new core presentation/manual-result helpers/tests, Android instrumented UI/transport tests as needed (not root VirtualMacPeerTest or Gradle/version inputs).
- [ ] RED cached-result/explicit response/older telemetry/error-success and fixed-layout tests.
- [ ] Manual result independent of incoming live snapshots, matching explicit commit before telemetry-order check; local progress/error reset;25s check timeout, same authentication limits.
- [ ] Calm paired connection presentation; fixed volatile text slots, stable trigger heading/time/Check; preserve full error/uncertainty meaning and existing design. Feedback overlays may avoid reflow; don't add a large blank box below reminders.
- [ ] Core/app/testcompile/lint and focused assertions; root runs shared emulators. Signed commit/report.

### Task 4: Root integration, review, emulator and packages
- [ ] Verify optional DTO compatibility and explicit-only check call sites; integrate reviewed commits.
- [ ] Port synthetic fixture for retained trigger assessments and deferred reads; run UI geometry/font-scale plus full GATT/transport cases. No actual power commands.
- [ ] Run full relevant suites and fresh final review; fix confirmed findings with regression tests.
- [ ] Versions Mac0.5.2/build14 + Android0.5.2/code5002, same owner signer/public Firebase config, safe Mac self-check and artifact receipts. Document manual semantics and test boundaries.
- [ ] Restore normal nearby setting after Internet trial when possible; user handles OS choices. Ask for USB only once prepared; install/test in place without losing pairing if connected.
