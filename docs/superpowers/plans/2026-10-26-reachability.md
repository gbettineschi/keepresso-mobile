# Reachability recovery

Owner request: stop repeated Awake/Unreachable transitions while naturally awake, and investigate lid closure. Complete free Personal Team signing setup when owner authentication permits it.

## Contract

- Unreachable remains correct when the Mac actually sleeps. Do not change native Keepresso or power settings, extend snapshot freshness, or replay commands.
- Retain a proven internet connection through an isolated transport/server failure only until its existing authenticated evidence expires (15 seconds). Authorization rejection and invalid authenticated payloads immediately remove authority.
- Sleep invalidates Bluetooth sessions; wake creates a fresh peripheral service and handshake. Never preserve an old encryption channel across sleep.
- Record only transport diagnostics (reason, status code and ages), without keys, identifiers, names, network names or payloads.

## Steps

1. Capture current physical evidence and reproduce transient poll failure in the actual Android service on a disposable emulator.
2. Correct bounded transient failure handling and cover authorization rejection/stale evidence. Add minimal transport diagnostics.
3. Make sleep/wake transport lifecycle explicit and test ordering using fake transport callbacks; preserve native-process lifecycle and pairing.
4. Run core suites, emulator service/GATT/relay coverage including a sustained foreground status observation, and one final read-only review.
5. Finish free Xcode/certificate setup with owner-controlled Apple authentication. Install verified in-place updates when signing is available; distinguish synthetic results from physical lid-close acceptance.

## Initial evidence

- macOS power history: 26 October 11:04:06 clamshell sleep; full wake 11:04:13. Therefore at least this lid-close loss was genuine sleep.
- Phone Bluetooth subscription at 11:05:27 was followed by its 300-second authorization timeout, not a repeated 5-second authenticated read timeout. Existing build has insufficient application diagnostics to identify why that handshake stalled.
- Mac main-thread sample did not show a sustained telemetry/AX block. Relay requests continued, mostly successful, while awake.
- Source: every HTTP poll failure clears RelayFreshness even if the last verified snapshot is only seconds old. Source: sleep/wake resets network/relay but retains Bluetooth manager/peer state.

Do not claim all physical cycling fixed merely because these reproduced recovery cases pass.

## Implemented and verified

- The decisive repeated relay fault was a time-of-check error: batch validation sampled time before processing; a successful status response recorded proof milliseconds later; the final reachability check used the earlier time and rejected that proof as future. An encrypted actual-service regression failed before sampling the final check time after batch processing.
- Both timestamp rollback directions, skipped busy keepalive, transient failure preservation and sleep-generation invalidation have regression coverage. Mac sleep closes nearby channels; wake creates a new service/handshake without changing saved pairing or power settings.
- Swift108 and Kotlin70 tests pass; eight Android actual-service regressions pass. Two-emulator virtual GATT approval/reconnect and slow-read/control tests pass. The deployed relay plus emulator passed120s of continuous foreground observation (every500ms), maximum snapshot age11.635s, duplicate synthetic mutation executed once, fixture authorization revoked afterward.
- Android0.4.2/code7 installed in place on the owner's phone; retained signer, app identity and encrypted pairing verified. Mac0.4.5/build9 packaged and self-checked as a development artifact; production installation awaits persistent signing. Official Keepresso and all107 pinned source files remain unchanged.
- Physical acceptance is incomplete: the previous Mac build rejected a first BLE write after subscription. Restarting that same canonical build reached managed startup; status remains unavailable pending the Mac's saved-authorization state. Free Xcode download is underway; no Apple signing identity is present yet.
