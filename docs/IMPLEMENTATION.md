# Development implementation

The repository is public. The Android and Mac applications implement nearby and optional owner-hosted internet transports, with automated protocol/state tests and native build checks. They have not completed the physical-device checklist. These are development builds, and the new protocol has not received an independent security audit.

## Present in the source

- Native Kotlin/Compose Android app named **Keepresso**, original Keepresso launcher/cup artwork, copper theme, Status/Activity/Settings, two-row Mac readings, manual duration stepper, capability-aware controls and trigger timestamp directly below **Active triggers**.
- Swift background Mac companion with a Finder/launcher settings window, no menu bar icon, with a locally initiated five-minute invitation QR, named-phone approval, saved authorization, revocation and opt-in nearby Bluetooth. Closing the window keeps it running invisibly; explicit Quit stops it. Optional **Follow Keepresso** enables macOS-managed hidden startup and crash recovery only after the owner clicks its button and approves it. Connections and reminders run only while native Keepresso is open. It does not modify or launch the official Keepresso app.
- Mutual authentication, separate encrypted directions, bounded BLE records/queues, strict sequence checks and fresh request expiry. Credentials use Mac Keychain and Android Keystore wrapping. A durable mutation journal reserves IDs before effects; uncertain commands are not replayed automatically.
- Ordinary native session status, lock/display/lid/battery/power and thermal-pressure readings. Unavailable or stale information remains distinguishable. An authenticated, fresh response is required before controls are enabled.
- Bounded trigger assessment using the unchanged pinned KeepressoCore in a separate worker. It uses disposable hook copies, preserves input uncertainty and runs only when the user selects Refresh. Current positive evidence is useful; unaudited negative reads remain unknown. A fresh partial assessment receives its own timestamp and **Some inputs unknown** label. A failed refresh retains the previous timestamp.
- Public Keepresso manual Start/Stop requests with observed-state acknowledgement. Pause/Resume uses an exact, uniquely exposed enabled Accessibility control when available; otherwise it is disabled. Stock manual/trigger semantics remain unchanged.
- Hourly/2-hour/off routine reminder policy, OK without moving the cadence, 6-hour routine-only snooze, resume, stopped-but-awake warning with 2/5/10-minute delay, and thermal warnings. Sleep and unknown restart gaps cancel ambiguous stopped-session warnings. Android notification actions require a reachable authenticated Mac; they do not queue a future power action.
- Optional nearby-first internet fallback using the existing pairing, direction-separated encrypted envelopes, pre-database access tickets, fresh Mac epochs and status round-trip gating. Mutation uncertainty survives Android restart; fresh read-only journal queries reconcile it without retransmission. Reminder outbox and phone event claims survive reconnect/restart. FCM uses encrypted data messages and expiring push leases; background fetches use bounded jobs. See [SELF_HOSTING.md](SELF_HOSTING.md) for service setup and budget assumptions.

## Limitations that matter

| Area | Current behavior |
| --- | --- |
| Distance | Nearby Bluetooth, or internet when the owner has configured and verified their relay and Firebase project. Physical handoff and locked-phone delivery remain acceptance work. |
| Sleep now | Disabled. A supported, verified safe native path is still required. Stopping a manual session merely allows normal sleep according to Keepresso/macOS settings. |
| Pause/Resume | Requires Accessibility permission and an unambiguous exposed native control in the supported app version. It may be unavailable when the native menu is not exposed or localized differently. |
| Temperature | Celsius and sensor name are unavailable. macOS thermal pressure is available as normal/warm/hot when supported. |
| Display dimming | Public readings distinguish on/off where possible. Dimmed is not inferred. |
| Battery safety pause | The native aggregate does not export trustworthy pause provenance. The original low-battery artwork is included, but percentage alone does not activate that icon. Battery-pause and sleep-failure warnings are not produced in this build. |
| Trigger negatives | Some upstream readers turn input errors into false. The companion conservatively keeps those negatives unknown until error-aware boundaries are verified. A grace-only hold never promises that native Resume will keep the Mac awake. |
| Updates | Observer compatibility is pinned to Keepresso 1.27.0. Official app updates continue independently; unsupported versions/settings disable assessment rather than silently using default rules. |
| Background delivery | Nearby uses a visible connected-device service; internet uses Firebase Messaging and bounded WorkManager tasks. Screen-off/Doze, Google Play services, vendor battery policy, Bluetooth range, Mac lid and sleep behavior require real-device testing. |
| Distribution | Development APK and ad-hoc Mac bundle. No Play Store release, notarization or unattended installation. |

The key next acceptance step is to pair the actual Android phone and Mac, inspect read-only status first, and then deliberately test commands and background reminders. Follow [ACCEPTANCE.md](ACCEPTANCE.md); no successful build or simulated acknowledgement substitutes for those observations.
