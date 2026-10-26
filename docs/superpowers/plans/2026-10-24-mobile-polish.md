# Keepresso Mobile refinement implementation plan

> **For agentic workers:** Use superpowers:executing-plans, implementing and verifying each task in this session.

**Goal:** Finish every item in the numbered refinement ledger with evidence.

**Architecture:** Retain the existing Kotlin/Compose Android app and Swift Mac helper, shared authorization and durable mutation journal. Separate cheap status, bounded trigger assessment, and user-command progress. Keep native Keepresso unchanged.

**Tech Stack:** Kotlin/Compose, Swift/AppKit/IOKit, existing Vercel/Firestore/FCM relay and two disposable Bluetooth emulators.

**Spec:** `docs/superpowers/specs/2026-10-24-mobile-polish-design.md`

## Global constraints

- Product name Keepresso Mobile; retain installed package, signing, storage and wire identities.
- No real power operations, permission grants, background-item changes or native setting writes while testing.
- Preserve unknown/stale values, fresh authenticated control, durable deduplication and no mutation replay.
- No continuous duplicate trigger engine; no native app patch/fork; no new server.
- Native Celsius data is optional, never fabricated; thermal colour uses system pressure.

## Review focus

- A command tapped during a silent poll waits briefly without global disabled flicker.
- Connection loss or expired wait discards unsent commands; submitted uncertainty never resends.
- Unknown trigger inputs cannot become false inactivity merely to simplify the UI.
- Startup/wake with a closed lid cannot masquerade as a newly observed closure.
- Notification channel and volume/DND policy remain controlled by the owner.

## Task 1 — dashboard and settings (01–10, 13, 15, 20)

- [ ] Add emulator rendering/interaction regressions for compact trigger rows, absence of agent/technical prose, duration/Start layout and quiet-poll control availability. Observe failures.
- [ ] Update MainActivity composables and Android label, splitting focused presentation helpers if needed. Use Check and a single compact trigger header, normal-weight facts, charging icon and grouped Settings.
- [ ] Verify light/dark screenshots and unknown/stale/long-label layouts in a dedicated emulator. Record each ledger outcome.

## Task 2 — telemetry and trigger assessment (03, 05, 06, 08, 10)

- [ ] Add tests for sensor selection/plausibility and error-to-product-message mapping; observe failures.
- [ ] Implement a read-only temperature adapter using vendored SMC reads; cache discovery, sample cheaply, no fan writes.
- [ ] Reproduce installed worker timeout with read-only measurement. Fix the actual boundary/initialization issue, keeping execution bounded and diagnostic details in structured logs.
- [ ] Preserve configured rule rows even when a check fails; unknown remains explicit through its icon/accessibility label. Run full Swift tests and an isolated live read.

## Task 3 — status and command scheduler (08, 11, 12, 15)

- [ ] Write core tests for coalesced reads, a short command wait, disconnect/expiry discard and no replay. Observe failures.
- [ ] Update NearbyService: two-second foreground BLE status, ten-second background, unchanged five-second relay budget. Mutation progress only; dispatch one queued command after read completion with fresh route/state.
- [ ] Verify repeated polls never disable controls in the emulator; run duplicates and reconnect regression.

## Task 4 — sleep (14)

- [ ] Add dependency-injected tests for stop acknowledgement, override release, blocked/unknown override, native restart and one system-sleep request. Observe failures.
- [ ] Replace hardcoded sleep rejection/capability with safe native-stop, release verification and IOKit request. No real invocation from tests/self-check.
- [ ] Test Android confirmation and uncertain/disconnected outcome on the synthetic peer. Document the owner-run physical acceptance.

## Task 5 — lid and warning delivery (16–19)

- [ ] Add persisted lid-edge/dedup tests, including unknown, startup, repeated closed samples, grace/reopen and snooze. Observe failures.
- [ ] Integrate lightweight lid/sleep-override observation, one sound/best-effort haptic on confirmed closure and shared-ID phone delivery.
- [ ] Add dedicated Android warning channel and system-setting entry points; test sound/vibration/DND metadata without granting real-device access.
- [ ] Verify routine/safety separation, Settings status, and draft the native closed-lid icon suggestion without posting.

## Task 6 — end-to-end and owner updates (12, 21)

- [ ] Extend two-emulator suite for the new UI, quiet polls, queued commands, warning delivery, sleep fakes and failover conditions.
- [ ] Measure authenticated local and live-relay synthetic round trips without controlling the real Mac; test duplicate IDs and remove synthetic cloud data.
- [ ] Run full relevant core, Swift, relay, Android lint/build and emulator checks; independent review; resolve findings.
- [ ] Build with retained signing identities, update canonical Mac app and Samsung in place, preserve pairing/settings and verify versions. Package ZIP only; no duplicate Mac launcher apps.
- [ ] Finish the ledger with evidence and material physical-device limits; push the source and update the draft PR.
