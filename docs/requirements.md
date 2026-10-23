# Keespresso — Android companion requirements

Updated: 23 October 2026. This records the requested behaviour and the updated interactive mockup. It is not a claim that a working Android app, Mac helper, Bluetooth link or internet service has been implemented.

Current scope: retain official Keepresso updates and avoid maintaining a personal app fork. Native setting renames and automatic restoration of trigger state after a manual timer are deferred. The user accepted bounded, on-demand refreshes of an independent trigger preview using KeepressoCore, with a small conditions timestamp in Android. A throwaway probe successfully compiled the unmodified v1.27.0 library, loaded the user's three saved rules and produced live rule/agent rows. This is a separate assessment using Keepresso's algorithms, not access to the running app's private state. Its grace history can disagree with the native app; cold-start, missing-input and version-mismatch states need explicit treatment. The Android app, persistent Mac helper and remote controls remain unimplemented. The v8 mock shows sample data, a separate trigger timestamp and a simulated Refresh control.

## Identity and appearance

1. The Android app label is **Keespresso**, using the spelling requested in chat.
2. Use the same app icon as the installed macOS Keepresso app, including the Android launcher icon. Reuse the original asset.
3. Use Keepresso's existing theme: burnt copper `#A64B23` in light mode, soft copper `#D98F52` in dark mode; preserve readable neutral surfaces.
4. Use the original Keepresso menu-bar coffee marks: filled cup with steam while brewing, outline cup without steam while idle, and the dedicated low-battery pause cup with its yellow last sip. Do not substitute generic coffee symbols. The low-battery cup indicates a battery safety pause, not merely a low percentage while still brewing.
5. Remove the previous Live badge. Show a last-contact/last-update time instead.

## Status screen and order

6. App header: original app icon and Keespresso name.
7. MacBook status: **Awake** or **Unreachable**.
8. Group all dashboard readings together in two rows: **Lock / Display / Lid** in the first row, **Battery / Temperature** in the second, with one thin separator between them. Show Locked/Unlocked, Display On/Dimmed/Off, Lid Open/Closed, battery percentage and power source, and temperature with a labelled severity. Temperature has no separate section.
9. Preserve unknown and last-known readings. An unreachable Mac must not be presented as currently off, asleep, locked or unlocked based only on a lost connection.
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

    Show a small **Triggers checked at 13:28** line directly below the **Active triggers** title, with a **Refresh** control, before the trigger list. Remove the Independent preview / sample data line from inside that section. Keep this timestamp separate from the general Mac status update time. Use the time of the last successful assessment; a failed refresh must preserve that time and mark the result stale/unavailable. During a refresh show Checking; before any successful result show Not checked yet. Preserve a date when the result is from an earlier day. While unreachable, show the last checked time and disable Refresh. This applies during both automatic and manual sessions.
20. Reuse a pinned KeepressoCore version for rule construction, any/all combination, agent detection and detail rows, microphone detection, download detection and grace logic. Read the existing saved rules without changing them. The user's current rules are agent activity with a 180-second grace, microphone use, and downloads in Downloads. A synthetic test confirmed that a continuously sampled observer's grace can survive after the paused native engine's grace has expired; a grace-only preview must never imply that Resume Triggers will keep the Mac awake. Use a read-only hook input adapter because the stock hook reader prunes files. Validate older shared-host Codex records, input availability and warm-up before product integration.
21. Put the **Pause triggers / Resume triggers** control below that section.
22. Add a separate manual-session control after the trigger control: **Manual session**, then a **− / duration / +** stepper with **Start** inline beside it, or **Stop manual session** when one is running. No duration text box. The current mock changes duration in 15-minute steps.
23. Retain a separate **Sleep now** action, with confirmation.
24. Retain simple Status, Activity and Settings navigation.

## Session and command behaviour

25. Starting a manual session uses the chosen duration and stock Keepresso semantics: trigger control is paused for the manual session.
26. Run the observer engine for a bounded assessment when opening/refreshing the condition preview, then stop its sampling. Do not keep the duplicate detector running merely because the phone dashboard remains open. Ordinary Mac status and reminders update independently, using the native lightweight session snapshot and separate macOS readings. The provisional refresh budget is 2–5 seconds, not a measured phone-to-Mac guarantee; CPU-only detection may need longer or remain uncertain. Show Checking while data is incomplete. The preview does not resume native trigger control, change the manual timer or create power holds. Never present observer-only grace or a cold-start negative as an authoritative native handover decision.
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

35. Send a reminder every hour while Keepresso is actively holding the Mac awake. Include the scheduled end if there is one, otherwise say there is no automatic end time.
36. **OK** dismisses that reminder and preserves the next regularly scheduled hourly reminder.
37. **Snooze 6 hours** silences routine reminders for this Mac for six hours. Show the end time and provide Resume reminders.
38. Snoozing notifications never extends, starts, stops or pauses a brewing session.
39. Proposed default retained from the earlier mock: battery, heat and sleep-failure warnings bypass the routine-reminder snooze.
40. Warn once when the session ends but the Mac has not slept after a grace period; the current draft uses five minutes, configurable in Settings.
41. Give stronger prominence to the case where system sleep remains disabled after Keepresso becomes inactive. Include the known reason when available.
42. Cancel an obsolete stopped-session warning if another legitimate session begins before it is due. Do not send a stale warning after the Mac slept and later woke normally.
43. Include battery/thermal pauses and relevant failures in the warning/activity experience without duplicate alerts for the same incident.
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

60. Add a temperature reading to the mobile dashboard, in °C, naming the selected sensor or sensor group. Show Unavailable when unsupported, and explicitly distinguish current, stale and unknown readings.
61. Show a readable thermal status as well as colour: normal stays neutral, elevated/warm is yellow, high/critical is red. Default classification should follow macOS thermal pressure; if Celsius thresholds are offered, make them configurable for the chosen sensor rather than presenting universal safe temperature cutoffs. The mock's numbers and thermal states are sample data, not calibrated limits.
62. Reuse Keepresso's original low-battery pause icon in Android and preserve its yellow accent in both light and dark appearance.

Keep native Keepresso setting names unchanged. Do not maintain a fork for wording changes.

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
