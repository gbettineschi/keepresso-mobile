# Keespresso Mac helper

Unofficial menu-bar companion for the unmodified Keepresso app. macOS 14+ to run, Swift 6.4 (Xcode/Command Line Tools 27) to build/test the unchanged upstream source. Bluetooth is enabled by the owner in the helper and that opt-in is remembered; no login item is installed.

## Build and verify

From repository root:

```sh
swift test --package-path macos
bash macos/scripts/build-app.sh
macos/artifacts/KeespressoMac.app/Contents/MacOS/KeespressoMac --self-check
```

The script uses Command Line Tools, builds a release executable, bundles original artwork/localizations, and ad-hoc signs `macos/artifacts/KeespressoMac.app`. It does not install or launch the normal helper. Self-check branches before AppKit initialization, credentials, Bluetooth, the observer, status readers or power adapters. No real power commands run in tests.

Swift 6.4 Command Line Tools currently require an explicit Swift Testing macro plugin path; Package.swift applies this only when that compiler/plugin is present. The default Swift build/test tool interface remains supported. Local CLT linker warnings about absent Developer framework search directories are environmental; production source compiles without concurrency warnings.

## Implementation boundaries

- CryptoKit implements the exact shared protocol and independently generated Node vectors. Each BLE central has its own bounded framing/notification queue. Private traffic starts only after mutual authentication. Pairing needs a local five-minute QR invitation and a local approval; credentials are in Keychain, revocation drops sessions immediately.
- A durable, synchronized mutation reservation precedes every side effect. The journal binds device, ID and body; crashes stay uncertain. The executor serializes all native mutations, including across phones, and never queues a rejected mutation or replays an uncertain operation. Journal corruption/full capacity disables controls.
- Start/Stop target the installed `/Applications/Keepresso.app` public URL interface. A fresh native status-file write and the requested resulting state are required for an acknowledgement. File modification time handles the native timestamp's whole-second precision. A same PID from a prior app launch is rejected.
- Pause/Resume require Accessibility permission, pinned version 1.27.0, and exactly one enabled, exposed native AX button/menu item with the exact expected English title and a Press action. No guessed menu opening or coordinate click is used. Localization or an absent/ambiguous control makes the action unavailable. Capability probing is bounded; it does not establish screen visibility.
- **Safe remote sleep is unavailable.** The public native URL interface does not expose an audited operation that releases all relevant trigger, lease and closed-display holds before sleeping. No direct `pmset`/AppleScript/IOKit force-sleep fallback exists. A future supported native safe-sleep operation can be implemented at `NativeCommands.execute`; it must still use the mutation journal and observed acknowledgement rules.
- Native status uses the current app process and `status.json`. A running app with unreadable/invalid status stays unknown; an observed absent app is known to have no brewing session. Global system sleep overrides may outlive that process and are not inferred inactive.
- macOS readings provide lock when available, display on/off, lid, battery/source and thermal pressure. Display dimming, Celsius, exact native safety-pause cause and battery safety warnings remain unavailable/unknown. Thermal-pressure warnings are supported and incidents persist across restarts.
- Reminders persist cadence, settings, snooze and warning incidents. OK keeps cadence; six-hour snooze affects routine events only. Observed sleep or an unknown helper-restart interval cancels an ambiguous ended-session warning. A session ending before a sleep sample cannot create a stale warning after wake. Nearby event delivery still depends on an authorized connected phone.

## Trigger observer

Only explicit Refresh launches a separate instance of this executable with the internal `--observe-triggers --observer-scratch <private-temp-path>` flags. The parent owns the scratch directory, caps output at 64 KiB, and starts termination after five seconds, then kills the worker process group, reaps it and removes scratch before returning. This is process isolation, not a real-time OS scheduling guarantee. Ordinary status/reminders never construct the duplicate engine or a power assertion.

The worker strictly decodes every saved rule before using KeepressoCore, preventing its intentionally lossy unknown-rule fallback. Hook readers receive disposable copies only; the adapter retains upstream's exact older shared-host Codex rollout-freshness exception. The original Sources files remain byte-identical; companion adapters also locate the unchanged localization resources in the standard signed app bundle.

HAL, file-stat and asynchronous upstream monitors can collapse failures into false. For the supported agent/microphone/download rules, matching positive evidence is retained and unaudited negative results are unknown; other rule types remain unknown. A completed valid partial assessment gets a new checkedAt with state unknown; timeout/settings/parse failure preserves the previous timestamp. Preview grace is independent of the running native engine and never promises safe handover. Physical microphone/download/agent transitions and signed-helper permissions remain acceptance work.

## Optional internet

The menu's Internet section accepts an HTTPS base URL and independent32-byte Base64 Mac bearer; both are validated and stored in Keychain. Owner-hosted server setup is in [SELF_HOSTING.md](../docs/SELF_HOSTING.md). Existing paired phones are enrolled and receive encrypted URL/access-ticket configuration on their next nearby session. No second authorization is needed.

While naturally awake the helper polls every5s and publishes ordinary native status every10s to phones without an authenticated nearby connection. An explicit command response flushes on the next app timer tick. Monitoring does not acquire a wake assertion. Wake, restart and15s contact gaps replace the relay epoch; commands returned after a slow awaited request are rechecked before execution. Both routes share the same durable mutation executor; `operation_status` looks up an original device/body-bound outcome without replay. Local revocation tombstones gate every route before fallible cleanup. Reminder outbox entries retain one encrypted identity across retries and expire; push retry failures do not block command polling.

Shared Node fixtures verify envelope keys, AAD and access tickets; fake HTTP tests exercise delay/reconnect, route preference, duplicate rejection and durable outbox recovery. A real deployment/phone test is still required. The custom protocol has standard cryptographic primitives but no independent audit or forward secrecy; compromised device keys and compromised endpoints remain outside its protection.

## Evidence and pending acceptance

`evidence/red-*.log` records actual expected test failures before implementations/fixes. `evidence/green-platform.log` contains the final full suite; `evidence/build-app.log` records the packaged build/self-check. Tests use fake native mutation adapters and temporary fixtures, never real Keepresso controls. Bluetooth hardware, QR pairing on Android, revocation, background notification delivery, closed-lid behavior, native controls, and permission behavior require owner-run acceptance. The local package is ad-hoc signed, not notarized.
