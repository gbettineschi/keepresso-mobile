# Keepresso — Android companion requirements

Updated: 24 October 2026. This records the requested behaviour and research baseline. See [implementation status](IMPLEMENTATION.md) for the first development build and remaining limitations; this document is not evidence of physical-device acceptance.

Current scope: retain official Keepresso updates and avoid maintaining a personal app fork. Native setting renames and automatic restoration of trigger state after a manual timer are deferred. The user accepted bounded, on-demand refreshes of an independent trigger preview using KeepressoCore, with a small timestamp in Android. A throwaway probe successfully compiled the unmodified v1.27.0 library, loaded the user's three saved rules and produced live rule/agent rows. This is a separate assessment using Keepresso's algorithms, not access to the running app's private state. Its grace history can disagree with the native app; cold-start, missing-input and version-mismatch states need explicit treatment. The v8 mock is a reference containing sample data; the native development app uses runtime readings and explicit unknown states.

## Identity and appearance

1. The Android app label is **Keepresso Mobile**, using the spelling requested in chat.
2. Use the same app icon as the installed macOS Keepresso app, including the Android launcher icon. Reuse the original asset.
3. Use Keepresso's existing theme: burnt copper `#A64B23` in light mode, soft copper `#D98F52` in dark mode; preserve readable neutral surfaces.
4. Use the original Keepresso menu-bar coffee marks: filled cup with steam while brewing, outline cup without steam while idle, and the dedicated low-battery pause cup with its yellow last sip. Do not substitute generic coffee symbols. The low-battery cup indicates a battery safety pause, not merely a low percentage while still brewing.
5. Remove the previous Live badge. Show a last-contact/last-update time instead.

## Status screen and order

6. App header: original app icon and Keepresso name.
7. MacBook status shows **Awake** with a fresh authenticated reading. During the first six seconds without one, show **Updating…** before switching to **Unreachable**. Reopening the dashboard starts a new wait if the reading is stale. Mac controls require a current authenticated connection throughout.
8. Group all dashboard readings together: **Lock / Display / Lid**, a thin separator, then **Battery / Thermal state**, and **Internet / Wi-Fi or Network** below. Show Locked/Unlocked, Display On/Dimmed/Off, Lid Open/Closed, battery percentage and power source, and the macOS thermal state with severity colour. Thermal state has no separate section.
9. Preserve unknown and last-known readings. An unreachable Mac must not be presented as currently off, asleep, locked or unlocked based only on a lost connection.

    Owner addition, 24 October: a compact third facts row shows the Mac's actual Internet check and current Wi-Fi name (or Ethernet/other network), independently of nearby Bluetooth. No route is Offline; a route without successful public HTTPS checks is Check failed. Unknown/Checking remain explicit; Wi-Fi permission is optional and denied/hidden names are unavailable, never inferred. No new notifications. Prepare and emulator-test this addition, then wait for explicit approval before installing either updated app.
10. Call the Keepresso session section **Brewing session**.
11. Display **Running** or **Not running**, accompanied by the original brewing/idle coffee mark.
12. Remove the large elapsed-session counter.
13. For a timed manual session, show its remaining time, for example **1h 18m remaining**. Elapsed time may remain in the activity history and hourly notification where useful.
14. Under a native-style manual session, show: **Manual session. Triggers are paused.** Do not promise automatic resumption when the timer ends.
15. While a manual session is running, show an independent preview calculated by KeepressoCore from the same saved rules. Use the small Triggers checked at… row for assessment freshness; do not add a separate Independent preview label. Distinguish current matches from grace-only holds, Checking while the initial asynchronous read is incomplete, and Unknown/Unavailable when relevant inputs cannot be read. Do not call it the running app's exact assessment. The mock's example matches remain sample data.
16. When no manual session is running and automatic triggers are holding the Mac awake, replace the countdown with **Active**.
17. Interpretation for the stopped case: show **Inactive** when no manual session or automatic hold exists, rather than falsely showing Active.
18. Below the brewing section, show a separate **Active triggers** section. Remove the former Why it is running label.
19. During trigger control, list known active holders when supported. During manual control, keep the Active triggers section and identify it as an independent preview using Keepresso's engine while native trigger control is paused. Matching suspended conditions are not active holders. Keep sample labels explicit until a real integration replaces them.

    Show **Active triggers**, **Checked 13:28** and **Check** on one line, before the trigger list. Remove the Independent preview / sample data line from inside that section. Keep this timestamp separate from the general Mac status update time. Use the time of the last successful assessment; a failed refresh must preserve that time and mark the result stale/unavailable. During a refresh show Checking; before any successful result show Not checked yet. Preserve a date when the result is from an earlier day. While unreachable, show the last checked time and disable Refresh. This applies during both automatic and manual sessions.
20. Reuse a pinned KeepressoCore version for rule construction, any/all combination, agent detection and detail rows, microphone detection, download detection and grace logic. Read the existing saved rules without changing them. The user's current rules are agent activity with a 180-second grace, microphone use, and downloads in Downloads. A synthetic test confirmed that a continuously sampled observer's grace can survive after the paused native engine's grace has expired; a grace-only preview must never imply that Resume Triggers will keep the Mac awake. Use a read-only hook input adapter because the stock hook reader prunes files. Validate older shared-host Codex records, input availability and warm-up before product integration.
21. Put the **Pause triggers / Resume triggers** control below that section.
22. Add a separate manual-session control after the trigger control: **Manual session**, then a **− / duration / +** stepper with **Start** inline beside it, or **Stop manual session** when one is running. No duration text box. The current mock changes duration in 15-minute steps.
23. Retain a separate **Sleep now** action, with confirmation.
24. Retain simple Status, Activity and Settings navigation.

## Session and command behaviour

25. Starting a manual session uses the chosen duration and stock Keepresso semantics: trigger control is paused for the manual session.
26. Run the observer engine once when the paired phone app opens or returns to the foreground, after an authenticated Mac connection is ready. The user can also tap Check. Stop sampling after each attempt. Ordinary status polling never checks triggers. Retain the last completed rows, verdicts and checked time through polling, route/session changes and failed attempts; only a successful check replaces them. Progress, changed-context information and attempt errors are separate from that result. Do not keep the duplicate detector running merely because the phone dashboard remains open. Ordinary Mac status and reminders update independently, using the native lightweight session snapshot and separate macOS readings. The engine watchdog is 8 seconds, with a 12-second parent bound allowing process startup, not a phone-to-Mac guarantee; CPU-only detection may need longer or remain uncertain. Show Checking while data is incomplete. The preview does not resume native trigger control, change the manual timer or create power holds. Never present observer-only grace or a cold-start negative as an authoritative native handover decision.
27. Manual expiry or stop leaves triggers paused, matching the unmodified app. Automatic return to the previous state, including timers started in native Keepresso, is deferred rather than implemented through an unreliable event/polling approximation.
28. Resume triggers is an immediate handover, ending manual timer control. Show a concise confirmation explaining that no current match may allow sleep and make the Mac unreachable. A detected condition can change; the preview is not a promise of continued wakefulness.
29. Respect Keepresso's separately configured end action. Do not describe allowing normal sleep as equivalent to issuing an immediate sleep command.
30. Stopping a manual session and pausing automatic triggers are separate controls with separate effects.
31. Sleep now confirms its consequences, stops relevant Keepresso holds/pauses triggers as required, and requests macOS sleep. Show command progress and the last acknowledged result; disconnection alone is not confirmation of completed sleep.
32. Keep remote wake outside the initial scope. While asleep/unreachable, show last-known status and disable Mac-control actions.
33. Never replay an old power command automatically when the Mac reconnects.
34. Do not blindly retry a command whose execution outcome is uncertain.

### Confirmed stock Keepresso behaviour — 23 October 2026

The intended companion policy above is not stock Keepresso behaviour. Source inspection of v1.27.0, matching the installed app, confirms:

- Starting a manual override first pauses trigger control. Expiry does not resume it. The pause lasts until Resume Triggers or an app relaunch; it is not persisted.
- Resume Triggers hands control back immediately, rather than scheduling a resume for the end of a manual timer. Trigger-controlled sessions ignore the manual timer cap.
- The menu hides trigger condition rows while triggers are paused, and the public status snapshot does not include per-rule matches. The retained internal engine could support a future read-only preview, but fresh sampling and grace-period semantics need explicit handling.
- Keep awake with lid closed controls a separate global sleep override; it does not start a brewing session. With Only while brewing enabled, that override follows any active session and its manual switch becomes read-only. Without that setting, a manually enabled override can outlive a session or the app.

Therefore resume-after-manual, independent companion controls and a reliable preview of currently matching paused rules require deliberate integration work. They must not be presented as already supplied by the existing CLI.

The internal rule engine remains allocated while trigger control is paused, but the normal session path no longer ticks it. No current file/API exports a reliably fresh per-rule snapshot. The installed CLI, MCP get_status, widget snapshot, App Intents and privileged helper interface were checked: none publishes this assessment. Hooks/history alone are insufficient as an authoritative live preview.

An upstream read-only export would remain the cleanest route to the actual app's assessment. The selected no-app-patch investigation instead reuses the open-source KeepressoCore library in a separate observer. Official app updates can continue normally. The observer's bundled library has its own pinned version and update/compatibility checks; it does not automatically change when the installed app updates. No upstream request has been posted and no installed app has been patched.

### Shared-engine feasibility evidence — 23 October 2026

- Built a separate executable against the v1.27.0 package. Verified all 107 copied KeepressoCore source/resource files against the tag, with no modifications.
- Read the real app's saved settings through its UserDefaults suite. Loaded the expected three rules and the Any combination.
- A live seven-sample run produced agent detail rows after the first asynchronous refresh, with the agent rule satisfied and microphone/download rules false at that time. The initial sample reported false before the asynchronous agent snapshot arrived. This demonstrates live evaluation, not exact agreement with the app or end-to-end positive/negative detection accuracy.
- Debug and optimized builds both completed 45-sample runs. The optimized run took 49.16 seconds, used 2.98 seconds of user CPU plus 1.10 seconds of system CPU (about 8.3% of one core on average), and reached 23.05 MB maximum resident memory. This short probe includes startup, JSON reporting and the disposable hook-copy adapter; it is not a battery benchmark or a production-helper budget. Continuous monitoring cost needs attention before deployment.
- A separate three-second stack sample showed recurring agent process discovery/classification and some Downloads enumeration. This suggests duplicated discovery is a meaningful cost; it does not establish an exact CPU breakdown. Prefer on-demand preview evaluation while the phone dashboard is open. Hourly reminders can continue to use the existing native session snapshot without this engine. No power or battery saving from that proposed lifecycle has been measured yet.
- A controlled synthetic test paused one engine while the other continued observing. On resume, the native-style engine reported false while the observer reported true solely through 160 seconds of remaining grace. This mismatch is an explicit product constraint.
- The default hook scan deletes stale files. The probe passed disposable copies to that reader, leaving the original hook inputs untouched. Its conservative adapter did not validate the private fresh-rollout exception for Codex Desktop shared-host records older than ten minutes; that branch remains an integration task.
- The probe created no SessionController, power assertions, automation leases or background service. It was not a sleep/wake, battery-impact, remote-control, Bluetooth or Android test. Microphone-on and real download start/stop transitions were not exercised.
- Downloads and preferences were readable from the current Codex-hosted process. A separately packaged helper's identity/permissions still need verification. The installed app has no separate loadable KeepressoCore framework, so the observer must bundle its own source-built engine. Invalid or newer unsupported settings must yield Unknown rather than silently use UserDefaultsSettingsStore's default-settings fallback.

Remote-control feasibility remains separate from preview feasibility: the public CLI/URL interface does not expose Pause/Resume Triggers. Before implementing that button, validate a no-patch adapter or obtain a supported upstream interface. The widget bridge is private and team-scoped, so its existence is not proof that an external helper can use it reliably. Do not claim these controls work merely because they appear in the mock.

## Reminders and warnings carried forward

35. Send one reminder after a fully awake Mac has brewed unattended for an hour, while a usable display is awake. Use the start of unattended brewing in the title.
36. Rearm after real user input or the brewing episode ends. Display/context transitions alone must not repeat an already-sent unattended reminder.
37. Preserve routine-snooze and reminder-enable preferences.
38. Snoozing alerts changes only their presentation.
39. Play Glass once at an observed physical open-to-closed lid transition, with confirmed full wake and no usable awake screen. No brewing prerequisite. Never play it on monitor standby, a refresh, or waking already closed. Retain the optional mute override.
40. After 60 continuous full-wake seconds without a usable awake display, keep one ongoing phone card. Say “Your Mac is running with the lid closed” or “Your Mac is running with the screen off”, according to the physical lid. Update the same incident silently across these contexts and when brewing changes. An awake external display makes closed-lid desktop use normal; its standby is treated as screen unavailability. A closed built-in display is excluded even if its framebuffer remains awake. Dim, lock and screensaver alone do not mean display sleep.
41. Include brewing mode, end time and Automatic handover. If brewing stops while the Mac remains awake, show “Keepresso is no longer brewing.” Refresh evidence every 90 seconds. After 180 seconds without fresh evidence, turn the card into quiet, dismissible history: “Your Mac was running…” / “Last confirmed at TIME.” Delivered full-wake normal context or sleep resolution clears it. Unknown evidence cannot refresh it; DarkWake hides it. Dismissal survives app restart, and old callbacks cannot overwrite newer evidence. Android removes an expired live card even without the app; quiet history may arrive later under OS scheduling restrictions.
42. New alerts require confirmed full wake. DarkWake never creates or refreshes one. Missing wake/display evidence is not proof of sleep or recovery.
43. Use the same authenticated Sleep now flow everywhere: Going to sleep, Couldn’t sleep, or Couldn’t request sleep. Historical notification actions never queue a power command while disconnected.
44. Retain a small activity history of session changes, trigger changes, reminders, snoozes, commands and outcomes.

Presentation refinement: keep the small reminder-status line, and remove the extra boxed feedback beneath it from the Status screen.

## Connection and authorization

45. **No Tailscale.** Do not require or use it for this project.
46. Nearby connection target: **Bluetooth Low Energy**, with automatic reconnect to the authorized Mac/phone.
47. Aim to avoid OS-level Bluetooth bonding/pairing if platform behaviour allows it. This remains a hardware feasibility check, not a tested guarantee.
48. Application-level authorization is mandatory even if OS-level Bluetooth pairing is avoided. Nearby Bluetooth discovery alone never grants control.
49. Use a one-time phone-authorization flow, preferably a QR scan initiated on the Mac; retain device identity afterwards. Normal platform Bluetooth/Nearby Devices permissions may still be necessary.
50. Only explicitly authorized device identities may read private status or issue commands. Provide a way to revoke a phone on the Mac.
51. Encrypt and authenticate the application messages. Protect device keys using the platforms' secure credential stores; do not use Bluetooth address, a public URL, a topic name or possession of the app as proof of authorization.
52. Reject forged, expired, replayed and duplicate commands. Use the same command identity across connection paths so switching paths cannot cause a second execution.
53. Optional remote connection target: an internet relay hosted on **Vercel**, if serverless is suitable. This replaces the earlier Tailscale proposal; it is not yet a deployment request.
54. Proposed relay shape: short-lived authenticated HTTPS requests, a small durable data store for pairing/revocation/latest state and bounded command/acknowledgment records, and a separate Android push-delivery path.
55. Keep long-lived monitoring and local Mac actions in the Mac helper. Serverless requests must not be treated as a permanently running Mac-control process or durable in-memory store.
56. The same phone authorization must work over both nearby and internet paths; do not make the user pair twice.
57. Product proposal: prefer the nearby path when available; enable internet access as an optional fallback. The final failover policy will be decided in architecture work.
58. With no available authorized path, display Unreachable and last-contact time. Do not silently queue sleep/stop commands for a future wake.
59. Monitoring alone must not acquire a keep-awake lease or intentionally wake the Mac. A hold may be created only for an explicit user-started session. Prove normal sleep, closed-lid operation and reconnection on real hardware.

## Temperature and additional status

60. Show Apple’s macOS thermal state in the mobile dashboard: Nominal, Fair, Serious or Critical. Show Unknown if no current reading is available.
61. Thermal onset requires full wake and either a physically closed lid, brewing, or a fresh native report that the thermal guard paused brewing. Base noncritical warnings on the configured native guard, no more than once per five minutes, with a 30-minute phone snooze. Once Critical starts, stopped brewing, lid opening, lost contact and unknown readings cannot resolve it. Keep the repeated standard Android notification tone until a confirmed lower Apple state or confirmed Ignore for five minutes; rearm after Ignore even without fresh telemetry. Use alarm audio without changing alarm volume. Silent ringer mode does not govern it; alarm volume zero, channel permissions, DND and full-screen access remain OS-controlled. Precise Ignore rearming requires Android’s optional Alarms & reminders access; otherwise Android may delay it. If exact-alarm access is revoked after scheduling, reopening the app is required to restore the saved alarm using the fallback. On confirmed recovery show the lower state and Sleep now/Dismiss. Force-stop, uninstall and revoked permissions remain platform limits.
62. Reuse Keepresso's original low-battery pause icon in Android and preserve its yellow accent in both light and dark appearance.

Keep native Keepresso setting names unchanged. Do not maintain a fork for wording changes.

## Guided setup and trigger coverage — owner correction, 29 October

63. Automatically show a simple setup flow on foreground opening for an unhandled app build or permission scope, including an already-paired owner. One **Continue** requests relevant permissions in sequence. Keep macOS allow/deny choices with the owner; never prompt from hidden login. Keep **Review setup…** for recovery rather than a collection of individual permission buttons. Preserve pairing and ordinary status updates while the owner answers.
64. Derive access from every configured native rule, not the owner's current three. Include companion Bluetooth, Wi-Fi name and optional remote-control needs. Do not request unrelated recording, Input Monitoring, Full Disk Access or Mac notification access. Declined inputs stay unavailable; complete setup can retain explicit skips without nagging.
65. Assess all 20 pinned Keepresso 1.27.0 trigger types through unchanged native matching and audited input boundaries. Verified complete input can prove inactivity; unavailable/cold/partial input remains unknown unless a direct positive is sufficient. Keep the independent observer's baseline/grace limitations explicit. Future unsupported upstream versions require a companion compatibility update. See [trigger support](TRIGGER_SUPPORT.md).

## Feasibility items for the architecture phase

- Verify unbonded Android-to-Mac BLE discovery, authorization, reconnect and behaviour with the lid closed. A nearby screen-off/background notification path also needs an explicit test.
- Complete the KeepressoCore observer adapter: read-only hook access, the older shared-host Codex freshness branch, settings refresh, explicit input availability, warm-up and library/app version compatibility. Confirm positive and negative microphone/download/agent transitions on hardware. Preserve the observed grace-history distinction.
- Keep native automatic trigger restoration out of the initial scope. Validate a no-patch path for remote Pause/Resume separately; do not assume existing public start/stop commands can resume triggers.
- Define trustworthy locked, display-dimmed and sleep-transition readings, including unknown states and external displays.
- Choose the durable store and Android push mechanism before claiming the Vercel relay is a complete remote-notification solution. ntfy remains a candidate for notification delivery, not an authorization mechanism.
- Validate authentication, revocation, replay rejection, duplicate suppression, stale-state handling and failover before enabling real power controls.

## References checked

- [Keepresso theme](https://github.com/gyorgysh/keepresso/blob/main/Sources/Keepresso/Theme.swift)
- [Keepresso original menu-bar mark](https://github.com/gyorgysh/keepresso/blob/main/Sources/Keepresso/BrandCupMark.swift)
- [Keepresso current public status snapshot](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/KeepressoCore/StatusFile.swift)
- [Keepresso internal trigger assessment](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/KeepressoCore/TriggerGateController.swift#L83)
- [Keepresso reusable package](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Package.swift)
- [Keepresso hook-reader cleanup](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/KeepressoCore/AgentHooks.swift#L680)
- [Keepresso asynchronous agent monitor](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/KeepressoCore/AgentActivity.swift#L296)
- [Keepresso widget snapshot](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/KeepressoCore/WidgetBridge.swift#L7)
- [Keepresso manual override and trigger control](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/Keepresso/AppModel.swift#L399)
- [Keepresso menu visibility and manual controls](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/Keepresso/MenuBarContent.swift#L208)
- [Keepresso closed-display controls](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/Keepresso/PreferencesView.swift#L839)
- [Keepresso trigger ownership and timer expiry](https://github.com/gyorgysh/keepresso/blob/v1.27.0/Sources/KeepressoCore/SessionController.swift#L801)
- [Android BLE GATT connections](https://developer.android.com/develop/connectivity/bluetooth/ble/connect-gatt-server)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Apple Core Bluetooth attribute permissions](https://developer.apple.com/documentation/corebluetooth/cbattributepermissions)
- [Vercel Functions](https://vercel.com/docs/functions)
- [Vercel persistent-storage constraints](https://vercel.com/kb/guide/is-sqlite-supported-in-vercel)
