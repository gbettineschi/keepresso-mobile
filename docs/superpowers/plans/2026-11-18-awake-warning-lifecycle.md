# Awake Warning Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct lid/screen-off activity warnings, retain truthful phone history, and scope thermal episodes without disarming them when brewing stops.

**Architecture:** A pure Mac display/context assessment feeds the existing awake-alert state machine. Keep one legacy-compatible activity incident across lid/screen-off contexts. Android derives live/history/hidden presentation from durable evidence and uses OS expiration plus a one-shot background fallback. Thermal eligibility gates episode creation only.

**Tech Stack:** Swift/Swift Testing, CoreGraphics/IOKit read-only adapters, Kotlin/JUnit, Android NotificationManager/AlarmManager/BroadcastReceiver, existing BLE/iroh/FCM transport.

**Spec:** `docs/superpowers/specs/2026-11-18-awake-warning-lifecycle-design.md`

## Global Constraints

- Native Keepresso and the 114 pinned vendored upstream files remain unchanged.
- Monitoring never acquires a sleep assertion, starts a lease, blocks sleep, or changes power settings.
- Preserve pairing, retained Android signing certificate, canonical Mac install path, credentials, existing settings and mute-override preference.
- DarkWake never starts or refreshes these warnings or a thermal alarm. Keep wake verification independent of screen power.
- Keep Bluetooth/iroh/FCM authorization, encryption, freshness, replay rejection and command deduplication unchanged.
- Never turn uncertainty, an unreadable display, or connection loss into proof of sleep or recovery.
- No new server, persistent Android foreground service, wake lock, exact-alarm permission, or private desktop-mode API for informative warning history.
- Real lid/display/power tests are owner-operated. Automated tests use pure fixtures, injected readers and an isolated emulator.
- Product wording is exactly the spec's live/history titles. History is silent and dismissible. First new live phone incident can sound even when waking already closed; Glass cannot.
- Unresolved Critical remains audible even when readings are stale, except during confirmed five-minute Ignore. Only a confirmed lower thermal state marks recovery. Use a gentle warning tone and existing alarm volume; never force maximum volume or promise to bypass denied OS settings.

## Review Focus

- Closed built-in framebuffer remains awake: it must not suppress an activity warning when no usable external screen is awake (Task 1).
- Context changes without input: neither the one-minute candidate nor the one-hour already-notified latch may create duplicate reminders (Task 2).
- Native guard stops brewing, readings become stale, or a ringing cap expires: retain the Critical episode and warning until actual recovery or explicit Ignore (Tasks 3 and 6).
- Old authenticated event or expiry callback arrives after newer evidence, DarkWake hiding, dismissal, reboot or unpairing: never resurrect or downgrade a card (Tasks 4–5).
- Android suspends/kills the process: do not retain a false live assertion indefinitely or promise an exact historical-posting deadline (Task 5).

---

### Task 1: Read usable-display evidence without changing power state

**Files:**
- Create: `macos/Sources/CompanionCore/MacDisplayAvailability.swift`
- Modify: `macos/Sources/KeepressoMac/NativeStatus.swift`
- Test: `macos/Tests/CompanionCoreTests/MacDisplayAvailabilityTests.swift`

**Interfaces:**
- Produces `MacDisplayAvailability: String, Codable` with `available`, `unavailable`, `unknown`.
- Produces `MacDisplaySample(isBuiltIn: Bool, isAsleep: Bool?)` and pure `MacDisplayAvailability.assess(lidClosed: Bool?, displays: [MacDisplaySample]?) -> MacDisplayAvailability`.
- Produces `MacDisplayAvailabilityReader.read(lidClosed: Bool?) -> MacDisplayAvailability`, with an injected online-display source for tests and a production CoreGraphics source. Return unknown on failed or inconsistent enumeration; never convert that failure into an empty successful list.
- `NativeStatus` owns the lightweight reader; do not run the duplicate trigger engine or add an independent periodic monitor.

- [ ] **1. Write failing assessment tests:** closed built-in awake + no external => unavailable; closed built-in awake + external awake => available; all eligible displays asleep => unavailable; one positive awake external plus another unknown => available; open lid and zero/missing topology => unknown; lid unknown and only built-in awake => unknown. Include mirror and two-monitor fixtures.
- [ ] **2. Run** `swift test --package-path macos --filter MacDisplayAvailabilityTests`. Expect the new behavior to fail before the adapter exists.
- [ ] **3. Implement the interfaces:** enumerate online displays, preserve per-display unknown, exclude a closed built-in panel, and validate IDs/topology coherently before publishing an all-off verdict. No brightness inference, private DesktopMode read or sleep command.
- [ ] **4. Rerun the assessment tests**, then existing observation/display tests; expect no failures and no actual power changes.
- [ ] **5. Commit** the display-evidence deliverable.

### Task 2: One activity incident, two copy contexts, closure-only Glass

**Files:**
- Modify: `macos/Sources/CompanionCore/AwakeAlerts.swift`
- Modify: `macos/Sources/CompanionCore/Reminders.swift`
- Modify: `macos/Sources/CompanionCore/Models.swift`
- Modify: `macos/Sources/KeepressoMac/NativeStatus.swift`
- Modify: `macos/Sources/KeepressoMac/CompanionModel.swift`
- Test: `macos/Tests/CompanionCoreTests/AwakeAlertTests.swift`
- Test: `macos/Tests/CompanionCoreTests/LidWarningSoundTests.swift`

**Interfaces:**
- Consumes Task 1 display availability plus existing verified wake, physical lid, session and input readings.
- Extend `MacAwakeReading` with `displayAvailability: MacDisplayAvailability` and update fixtures explicitly; unknown is not normal context.
- Add `MacAwakeContext: String, Codable` values `normal`, `lid_closed`, `screen_off`, `unknown`; its pure assessment uses the spec table.
- `CompanionEvent.awakeContext` is optional and contains only `lid_closed` or `screen_off` for `lid_awake` events. Add `mac.awakeContext` to snapshots without replacing the real `lid` value.
- Keep `ReminderMachine.observeAwake(_:now:)` and `consumeLidClosureSound()` as public entry points. Keep wire/delivery kind `lid_awake`.

- [ ] **1. Write failing sequence tests:** first warning at exactly 60 seconds; no warning at 59; 90-second quiet evidence updates; brew ending during the candidate minute retains “no longer brewing”; already-closed full wake gets a new active phone incident with no Glass; DarkWake gets neither.
- [ ] **2. Write failing continuity tests:** lid_closed→screen_off keeps ID and elapsed candidate time; one available external screen resolves; unavailable→normal→unavailable creates a new incident; unknown breaks confirmation continuity without proving resolution. An expired persisted closure cue cannot sound on restart.
- [ ] **3. Write failing Glass tests:** one observed physical close with unavailable displays produces one immediate cue regardless of brewing; external screen available suppresses it; screen standby, monitor disconnect, brew changes and updates never produce a cue. Unknown evidence does not invent a delayed closure sound.
- [ ] **4. Write the hour-boundary tests:** open→desktop normal transition preserves timing; 40 minutes normal plus 20 minutes confirmed non-visible and then normal without input makes an unsent reminder eligible; an already-notified episode is not rearmed by display changes or reconnection alone.
- [ ] **5. Run** `swift test --package-path macos --filter AwakeAlertTests`; observe the expected regressions.
- [ ] **6. Implement context-driven observation and optional fields.** Keep physical lid-edge tracking separate from display transitions and phone incident phase. Preserve backward decoding of saved reminder state; invalidate untrusted continuity on load as today.
- [ ] **7. Run** `swift test --package-path macos --no-parallel`; require all suites to pass. Verify no native/vendored file changed.
- [ ] **8. Commit** the Mac activity-state deliverable.

### Task 3: Gate thermal onset and retain the episode through guard intervention

**Files:**
- Modify: `macos/Sources/CompanionCore/Reminders.swift`
- Modify: `macos/Sources/KeepressoMac/CompanionModel.swift`
- Test: `macos/Tests/CompanionCoreTests/AwakeAlertTests.swift`
- Test: `macos/Tests/CompanionCoreTests/ThermalEpisodeScopeTests.swift`

**Interfaces:**
- Add `MacThermalAlertExposure(lidClosed: Bool?, isBrewing: Bool?)`.
- Change `ReminderMachine.observeHeat(_:exposure:now:) -> CompanionEvent?`. Positive onset eligibility is exposure.lidClosed==true OR exposure.isBrewing==true OR reading.brewingPaused==true (the latter is already validated against recent matching native thermal evidence).
- Existing persisted `CriticalIncident` remains the episode latch; exposure is not a per-tick cancellation predicate.

- [ ] **1. Write failing onset tests:** closed/nonbrewing qualifies; open/brewing qualifies; open/nonbrewing does not start; unknown/unknown does not start; open/nonbrewing with a fresh matching thermal pause qualifies. The source of thermal state remains ProcessInfo and the configured native guard report.
- [ ] **2. Write failing persistence/recovery tests:** start Critical while brewing, stop brewing and open lid, serialize/reload, continue Critical and preserve incident ID; unknown does not resolve; a confirmed Serious/Fair/Nominal resolves the same ID. Normal display context is irrelevant to thermal eligibility.
- [ ] **3. Write noncritical throttling tests:** eligible native-guard warning repeats no faster than 300 seconds even after a brief recovery/re-entry; do not invent a warning from raw Serious alone without guard activity. Preserve phone snooze duration of 30 minutes.
- [ ] **4. Run the new tests, implement onset-only eligibility, then rerun the full Mac suite.** No new native pause/resume/sleep command is introduced.
- [ ] **5. Verify that the existing Critical incident persists through an exposure loss and that Task 6 can use its active/recovered evidence without reinterpreting an inactive brew as cooling.** No timer or absent native status may manufacture a recovery event.
- [ ] **6. Commit** the scoped thermal-episode deliverable after its selected acceptance cases pass.

### Task 4: Android activity-state interpretation and compatibility

**Files:**
- Create: `android/core/src/main/kotlin/io/github/gbettineschi/keepressomobile/core/AwakeCardState.kt`
- Modify: `android/core/src/main/kotlin/io/github/gbettineschi/keepressomobile/core/AlertIncident.kt`
- Modify: `android/core/src/main/kotlin/io/github/gbettineschi/keepressomobile/core/Recovery.kt`
- Test: `android/core/src/test/kotlin/io/github/gbettineschi/keepressomobile/core/AwakeCardStateTest.kt`
- Test: `android/core/src/test/kotlin/io/github/gbettineschi/keepressomobile/core/AlertIncidentTest.kt`
- Test: `android/core/src/test/kotlin/io/github/gbettineschi/keepressomobile/core/LidEventTest.kt`

**Interfaces:**
- `AwakeWarningContext` has `LID_CLOSED`, `SCREEN_OFF`; missing event field means legacy LID_CLOSED, malformed/unsupported values reject without changing current state.
- `AwakeCardPresentation` has `LIVE`, `HISTORICAL`, `HIDDEN`.
- `AwakeCardState` carries incident, latest event ID, context, observedAt, optional elapsed deadline/boot count, dismissed-evidence ID and optional DarkWake suppression time. `presentation(nowElapsed: Long, currentBoot: Int)` is pure. RESOLVED, dismissed current evidence and DarkWake-hidden evidence are HIDDEN; absent/expired/unverifiable elapsed evidence is HISTORICAL, never live.
- Event claims retain current encryption/replay/expiry boundaries. Update snapshot supersession to use new context evidence; physical open alone cannot supersede SCREEN_OFF.

- [ ] **1. Write failing 179/180/181-second and old-boot tests**, including backward wall-clock correction. Stale is history, not resolved.
- [ ] **2. Write failing ordering tests:** same-event duplicate, retired incident, resolution winning at equal timestamp, late initial ACTIVE aged 181–299 seconds becoming quiet history, and >300-second packets remaining rejected by the existing freshness boundary.
- [ ] **3. Write snapshot/dismissal tests:** normal context clears; unknown leaves evidence unrefreshed; fresh DarkWake hides and suppresses scheduled history; only a newer positive full-wake event can re-show. Physical lid open does not dismiss a screen-off card. Dismissed evidence cannot resurrect; a genuinely newer event can return silently.
- [ ] **4. Run** `./gradlew :core:test` from `android`; observe failure, implement the pure model and compatibility changes, then require a green run.
- [ ] **5. Commit** the Android interpretation deliverable.

### Task 5: Android rendering, durable expiry and quiet historical replacement

**Files:**
- Create: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/AwakeStatusAlerts.kt`
- Create: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/AwakeAlertReceiver.kt`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/WarningIncidents.kt`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/AlertNotifications.kt`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/RemoteMessaging.kt`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Test: `android/app/src/androidTest/java/io/github/gbettineschi/keepressomobile/IncidentAlertTest.kt`
- Test: `android/app/src/androidTest/java/io/github/gbettineschi/keepressomobile/AwakeAlertLifecycleTest.kt`
- Create test harness: `android/scripts/test-alert-process-loss.py` and `android/app/src/androidTest/java/io/github/gbettineschi/keepressomobile/AlertProcessFixtureTest.kt`

**Interfaces:**
- Move the existing `LidAlert` object into AwakeStatusAlerts.kt; retain its name, saved key and caller-facing accept/snapshot/restore entry points to limit churn. Its rendering consumes Task 4's pure state.
- `AwakeAlertReceiver.onReceive(Context, Intent)` handles explicit expiry and dismissal intents plus boot/package reconciliation. It only reads authorized local state and renders/cancels the app's notification; it cannot issue Mac commands.
- The host test harness accepts an explicit emulator serial, verifies `ro.hardware == ranchu` before any mutation, prepares deterministic synthetic evidence through a fixture instrumentation run, then kills the debug app process without force-stop and observes system-owned notifications. A second instrumentation run verifies restoration and clears the fixture. Do not kill an active instrumentation run and call its interruption a passing test.
- Immutable explicit PendingIntents identify Mac, incident and latest event. Add only normal RECEIVE_BOOT_COMPLETED permission; keep receivers non-exported and credential-encrypted data unavailable until normal unlock.

- [ ] **1. Write failing instrumentation tests** behind EmulatorOnlyRule: same tag/ID changes from ongoing live to non-ongoing silent history; history has exact title and last-confirmed time/date; Sleep now still opens the existing result flow. Late initial delivery never beeps.
- [ ] **2. Write failing callback races:** fresh evidence at 179 seconds defeats old expiry; resolved/unpaired state defeats queued work; DarkWake hiding prevents an old historical post; historical swipe persists across app/process restart. A pre-deadline live-card dismissal acknowledges that evidence; an after-deadline live deletion is not treated as proven user dismissal, because OS timeout may invoke deleteIntent on some platforms.
- [ ] **3. Run the focused instrumentation tests on the isolated emulator and observe failure.** Verify hardware is ranchu before any emulator permission/device-state operation. Never target a connected physical phone for these tests.
- [ ] **4. Implement durable scheduling/rendering:** CredentialStore.writePrivate already commits synchronously; save evidence before scheduling. Keep Handler fast path, add one inexact ELAPSED_REALTIME_WAKEUP PendingIntent alarm, and retain OS live-card timeout. History has no timeout and no ongoing flag. Same tag/ID is preferred; if already removed, post the quiet replacement. Receivers reload and validate current state rather than trusting intent payloads.
- [ ] **5. Wire restoration into app startup without bypassing it through KeepressoApplication's Firebase early return.** Reconcile boot after unlock and package replacement. Preserve all current Firebase setup and pairing paths. Pair removal cancels pending local work or makes every pending callback harmless through authorization validation.
- [ ] **6. Run core tests, Android lint and debug/test packaging.** Then run the incident and new lifecycle instrumentation classes. On the emulator only, use the two-stage host harness for normal process loss, and verify deep Doze and reboot; record real fallback delay rather than asserting exact 180-second execution. Force-stop is a documented boundary; reconcile on subsequent launch.
- [ ] **7. Commit** the Android lifecycle deliverable after applicable checks pass. Report any broader-suite failures by name instead of calling the entire suite green.

### Task 6: Persistent Critical warning, gentle tone and durable Ignore

**Files:**
- Modify: `android/core/src/main/kotlin/io/github/gbettineschi/keepressomobile/core/AlertIncident.kt`
- Create: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/CriticalAlarmReceiver.kt`
- Create: `android/app/src/main/res/raw/critical_warning.wav`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/WarningIncidents.kt`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/AlertNotifications.kt`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/MacAlertActivity.kt`
- Modify: `android/app/src/main/java/io/github/gbettineschi/keepressomobile/WarningAlertSettings.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Test: `android/core/src/test/kotlin/io/github/gbettineschi/keepressomobile/core/AlertIncidentTest.kt`
- Test: `android/app/src/androidTest/java/io/github/gbettineschi/keepressomobile/IncidentAlertTest.kt`
- Test: `android/app/src/androidTest/java/io/github/gbettineschi/keepressomobile/CriticalAlarmLifecycleTest.kt`

**Interfaces:**
- Preserve `CriticalAlarmStatus` values; STALE describes evidence, not a recovered or silent alarm. Snooze takes precedence over freshness.
- Extend `CriticalAlarmState` with `needsAttention(now: Instant): Boolean`; it is true for unresolved unsnoozed Critical or STALE. `shouldRearm(now)` permits unresolved stale episodes after Ignore expires.
- `CriticalAlarmReceiver.onReceive(Context, Intent)` validates current pairing, incident and snooze version before ringing. Persist deadlines before canceling the current alarm; use monotonic time within a boot and the spec's bounded previous-boot fallback.
- Define one new Critical channel ID `critical_heat_alarm_v2`, a resource-name sound URI ending `/raw/critical_warning`, AudioAttributes.USAGE_ALARM and high importance. Keep the activity channel ID unchanged; never set the phone's alarm-stream volume. A current unresolved alarm has no fixed notification timeout.
- Manifest declares SCHEDULE_EXACT_ALARM for Critical Ignore rearming only. On API31+ inspect canScheduleExactAlarms; settings offer a single link to system special access. Use an inexact fallback when denied/revoked and report that timing may be delayed. No auto-grant, perpetual foreground service or app wake lock.

- [ ] **1. Write failing pure state tests:** freshness expires at 90 seconds without ending attention; snoozed Critical remains snoozed when it becomes stale; at 300 seconds unresolved stale Critical needs rearming; confirmed recovery wins over any pending snooze callback.
- [ ] **2. Write failing isolated instrumentation tests (and the Task 5 two-stage host harness for actual process death):** a fresh alarm becomes stale without switching to a quiet channel, losing its Ignore action or expiring after five minutes; process loss retains the OS-owned warning; a fresh lower-state event stops sound and shows the recovered presentation. Test old/new incident and pairing-removal races.
- [ ] **3. Write failing snooze-receiver tests:** a callback at the old deadline cannot interrupt a newer Ignore; elapsed time survives wall-clock rollback; repeated app starts do not extend Ignore; previous-boot restoration obeys the five-minute bound. Exercise both exact-permission allowed and denied scheduling using injected scheduler fakes, then the isolated emulator.
- [ ] **4. Implement the pure lifecycle and durable rearming, keeping 90-second freshness only for copy.** Remove the automatic five-minute ringing cap from unresolved attention. Unknown temperature, lack of contact and brew stop never mark recovery or silence an unsnoozed episode. Foreground and background restoration share the same persisted decision.
- [ ] **5. Prepare and preview the original gentle warning cue:** short two-note sound plus pause, approximately four seconds per pattern, no siren or escalating volume. Preserve alarm-volume/DND/notification controls. Do not trigger an alarm on the physical phone for audition without the owner's action; provide an ordinary playable preview first.
- [ ] **6. Implement the dedicated sound channel and concise settings readiness.** Read sound/DND readiness from the new Critical channel, preserving an already-allowed DND exception only where Android permits it; never override an explicit user block. The settings Test alert plays one gentle pattern without creating an unresolved Critical incident or a looping alarm. Alarm screen shows truthful last-reported Critical copy when stale, with Sleep now/Ignore. History's inexact scheduling and Critical's snooze scheduling remain separate, with distinct receiver identities.
- [ ] **7. Run core and Critical/lifecycle instrumentation tests**, including an unresolved warning beyond five minutes, denied-permission fallback, recovery after process restart, and no automatic volume changes. Report OS permission and force-stop limits honestly.
- [ ] **8. Commit** the Critical alarm deliverable separately from activity warning history.

### Task 7: Integration, documentation and reviewable delivery

**Files:**
- Modify: `docs/requirements.md`, `docs/protocol.md`
- Create: `docs/releases/0.6.12.md` after confirming that version remains unpublished
- Modify on release preparation: `android/app/build.gradle.kts`, `macos/scripts/build-app.sh` to version 0.6.12 / code 6012

- [ ] **1. Review the implementation against every spec section** and run `git diff --check` plus `python3 scripts/verify-upstream.py`. Require all pinned upstream files unchanged and no credentials/activity logs in the diff.
- [ ] **2. Run the full Mac suite, Android core tests/lint/build and focused emulator lifecycle suite.** Existing cryptography, command freshness and deduplication suites must remain green. Use packaged `--self-check` without launching a second helper or mutating real power state.
- [ ] **3. Request a fresh whole-branch review.** Fix actionable findings, then rerun only affected checks plus the required final integration checks justified by the edits.
- [ ] **4. Prepare a signed in-place preview and concise notes.** Verify Android retained certificate, package and monotonic version code; preserve Mac identifier, saved private connection and canonical path. Explain that both companions are required for screen-off semantics, and that Android historical replacement can be deferred after OS live-card expiry.
- [ ] **5. Perform owner-operated physical checks after arranging the test window:** real lid close with and without awake external monitor; open-lid screen sleep; external-monitor standby while closed; screen wake; cable removal; brief real system sleep and reconnection. Record full-wake versus DarkWake independently of display state. Do not induce real Critical heat, start keep-awake leases or change settings on the owner's behalf.
- [ ] **6. Integrate/publish/install through the existing owner-authorized preview channel when the reviewed change is ready.** Preserve pairing and one canonical Mac installation. If owner hardware tests are pending, name them in preview notes and do not claim them completed. No extra Mac/native installation is created.

## Planning self-review and execution handoff

Map every spec section to Tasks 1–7 and keep public fields/signatures consistent. The owner selected continued Critical sound on stale evidence and a gentle warning tone; no unresolved sound-policy choice remains. Recommended execution is native/inline for this coupled state-machine change, with one fresh final reviewer; separate task commits retain review boundaries without a fresh implementation context for every small change.

Only planning documents are changed at this stage. The installed 0.6.11 applications remain unchanged. The owner reviews this design/plan before implementation begins.
