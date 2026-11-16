# Additional thermal cutoff — exploration only

31 October 2026. Requested by the owner as investigation alongside the Internet migration. No automatic safety action, native setting change, new permission or implementation is authorized by this note. Native Fair/30s remains unchanged.

## Verified starting point

The installed native 1.27.0 commit is `16a5fe8aeac6caf981feb9e920d8d13e2de0764a`. Its ThermalGuard counts all samples at/above the chosen level through one dwell; it has no Critical fast path. The guard is armed only with a closed lid and active global sleep override. Thermal state is macOS’s assessment, not a fixed Celsius threshold.

The companion already has SafeSleep: pin the native process and launch date, issue its supported Stop URL, require a fresh stopped/trigger-paused snapshot, verify `SleepDisabled=false`, then request sleep once. A persistent override blocks that path; an accepted sleep request is not proof that sleep occurred.

## Practical approaches

1. **Stop brewing only:** small and prompt-free, but cannot remove a persistent global override. Insufficient to promise that the Mac sleeps.
2. **Local Critical/5s → stop, verify release, request sleep:** preferred investigation direction. Keep native Fair/30s. Reuse the verified control boundary, with explicit blocked/unknown outcomes and urgent Android incident delivery. Do not wait for Internet before acting. Best fit with native Only while brewing.
3. **New privileged companion helper:** could clear the global flag, but adds administrator consent, privileged maintenance and update/security complexity. Native’s installed helper authenticates its upstream app identity/team and cannot simply be borrowed by this companion. Do not choose this implicitly.

## Constraints for a later design

- Observe Critical separately with public ProcessInfo initially; existing mobile `hot` merges Serious/Critical and is insufficient. Native prefers a private Darwin notification, so signal timing can differ.
- Run independently of phone authorization, Bluetooth and Firebase. Existing CompanionModel timer starts after saved-pairing access and checks warning state every 10s; it is not an adequate safety controller.
- No awake assertion, scheduled wake, automatic native-app launch or duplicate trigger engine. Reset observation across sleep, native restarts and sample gaps. Use monotonic time; 5s is observed dwell plus scheduling/action delay, not a physical-temperature deadline.
- Serialize against remote Start/Resume. One incident at a time. Default proposal: no automatic resume after emergency stop. Native trigger pause is volatile across native relaunch, and other native controls can restart brewing; do not promise an internal native safety latch.
- Report Critical detected / Stop verified / Sleep requested / Blocked by closed-lid mode / Outcome unknown separately. Do not mislabel a companion stop as native `safetyPause=thermal`. Connection loss is not sleep confirmation.
- Surface unavailable local control honestly. Test all effects with injected fakes; no automated thermal stress or real power action.

## Evidence pointers

Companion: `macos/Sources/KeepressoMac/NativeStatus.swift`, `macos/Sources/CompanionCore/SafeSleep.swift`, `macos/Sources/KeepressoMac/CompanionModel.swift`.

Exact native commit: [thermal guard](https://github.com/gyorgysh/keepresso/blob/16a5fe8aeac6caf981feb9e920d8d13e2de0764a/Sources/KeepressoCore/ThermalGuard.swift), [stop handler](https://github.com/gyorgysh/keepresso/blob/16a5fe8aeac6caf981feb9e920d8d13e2de0764a/Sources/Keepresso/AppModel.swift#L2153), [helper admission](https://github.com/gyorgysh/keepresso/blob/16a5fe8aeac6caf981feb9e920d8d13e2de0764a/Sources/keepresso-helper/main.swift#L108). Apple: [thermal state notifications](https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification), [sleep request API](https://developer.apple.com/documentation/iokit/1557121-iopmsleepsystem).

This is an assessment, not an approved implementation design or tested safety guarantee. Ventilation remains necessary; software safeguards do not make closed-bag operation safe.
