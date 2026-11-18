# Awake warnings, display sleep and thermal episodes

Status: consolidated design for owner review; application code and installed apps remain unchanged.

## Intent and accepted decisions

Make continued Mac activity visible when its usable screens are off, without equating screen sleep with system sleep. Keep one informative phone warning and preserve truthful history when contact is lost. Keep thermal alarms independent of the brewing that the native guard may stop.

Owner decisions on 18 November 2026:

- Glass only on an observed physical open-to-closed lid transition. No Glass for screen standby, including a monitor entering standby while the lid is already closed. No brewing requirement for Glass.
- A desktop setup is normal-use context while at least one usable screen is reported awake. When that external screen sleeps and none remains usable, the closed-lid exception ends.
- An open-lid Mac with all usable screens asleep receives a screen-off phone warning after one minute, with the same lifecycle as the closed-lid warning.
- Three minutes without confirmation produces dismissible, silent historical information. Updating the same notification is preferred; removal followed by a quiet replacement is acceptable.
- Start companion thermal warnings when the Mac is fully awake and at least one applies: physical lid closed, brewing active. A guard-reported thermal pause counts as evidence of brewing stopped by that guard.
- Stopping brewing does not end a thermal episode. A Critical episode recovers only on a confirmed Apple thermal state below Critical; opening the lid or missing readings cannot manufacture recovery.
- Plan and review before implementation. Do not modify native Keepresso for this work.

## Approaches considered

1. **Native DesktopMode as the notification exemption.** A kernel property is readable, but modern Apple Silicon powerd has additional private desktop state. It needs hardware validation and would still require display-power evidence for this requirement.
2. **Usable-display evidence plus physical lid (recommended).** Public CoreGraphics display power and physical lid readings directly express the accepted rule. An awake external display supplies normal-use context even on battery; AC remains factual dashboard information, not a notification exemption requirement.
3. **Infer system sleep from screen sleep or connectivity.** Rejected: both can change while the Mac keeps running.

The design uses approach 2. It assesses screens as macOS reports them; it does not promise that a monitor is physically visible to a human.

## Constraints

- Native Keepresso and the 114 pinned vendored upstream files remain unchanged.
- Monitoring never acquires a sleep assertion, starts a lease, blocks sleep, or changes power settings.
- Preserve pairing, retained Android signing certificate, canonical Mac install path, credentials, existing settings and mute-override preference.
- DarkWake never starts or refreshes these warnings or a thermal alarm. Keep wake verification independent of screen power.
- Keep Bluetooth/iroh/FCM authorization, encryption, freshness, replay rejection and command deduplication unchanged.
- Never turn uncertainty, an unreadable display, or connection loss into proof of sleep or recovery.
- No new server, persistent Android foreground service, wake lock, exact-alarm permission, or private desktop-mode API for informative warning history.
- Real lid/display/power tests are owner-operated. Automated tests use pure fixtures, injected readers and an isolated emulator.

## Evidence and normal-use context

Take a coherent reading of verified wake, physical lid, online displays and native session evidence. An online display may be asleep or mirrored; do not use only the active-display list. Exclude the built-in panel from usable screens when the physical lid is closed, even if its framebuffer remains awake.

Classify display availability as available, unavailable or unknown:

- One positively awake eligible display proves available.
- Unavailable requires a successful, coherent enumeration with every eligible display asleep; a closed lid with a confirmed absence of external displays is also unavailable.
- Unreadable/contradictory topology is unknown. A zero-display result with an open or unreadable lid is unknown.
- A closed built-in panel cannot prove availability. Screensaver, lock, dimming and black content do not mean display sleep.

| Verified full wake | Usable displays | Physical lid | Notification context |
|---|---|---|---|
| yes | available | either | normal |
| yes | unavailable | closed | lid_closed |
| yes | unavailable | open | screen_off |
| unknown/dark | any | any | unknown/ineligible |
| yes | unknown | any | unknown |

Normal context feeds the existing one-hour unattended-brewing reminder. Known open-lid to external-monitor transitions preserve the timer and already-notified latch. A display transition alone must not rearm a reminder already sent during the same unattended brewing episode. Existing real-input and brew-end rearming remains. An unnotified timer counts confirmed continuous full-wake brewing without input across screen-off intervals too, but emits the one-hour reminder only in normal context. Thus 40 minutes normal plus 20 minutes non-visible makes it eligible immediately on return to normal if no input resumed. Unknown wake continuity or actual sleep resets elapsed continuity; an already-notified episode is not rearmed by that alone.

Virtual displays, dummy adapters and monitor power/input switches can differ from physical visibility. Validate the owner's real display/dock. Document unsupported or unverified topologies instead of claiming universal physical-screen detection.

## Glass

At the first verified open-to-closed edge, play Glass once if no usable external screen is positively awake and display unavailability is confirmed. Do not wait for the phone's minute or require brewing. Suppress on initial already-closed readings, wake/restart, unknown continuity and ordinary external-monitor desktop use.

Never play Glass on a screen-power transition, monitor disconnect/reconnect, brewing change, notification refresh or a new already-closed wake. Glass marks the closure event; it does not certify that system sleep failed. A normal subsequent sleep can still follow it. Existing optional mute override and restoration remain untouched.

## One non-visible activity incident

Start the candidate period when full wake plus a confirmed non-visible context begins. After 60 continuous seconds publish one phone incident. A full wake already closed qualifies; the first phone warning is normal-priority and can sound, independently of Glass.

- lid_closed title: **Your Mac is running with the lid closed**
- screen_off title: **Your Mac is running with the screen off**
- Body: existing Automatic/Manual/end-time/Automatic-handover wording. Preserve brewing observed during the waiting minute, so a stopped brew becomes **Keepresso is no longer brewing.**
- Update silently when the context or brewing changes; refresh evidence every 90 seconds.
- Switching lid_closed to screen_off without an intervening visible screen keeps the incident ID and candidate timer. It changes copy, not the alert count.
- A confirmed usable screen or system-sleep transition ends the incident. Fresh DarkWake evidence on the phone hides the current activity card, cancels its pending historical replacement, and prevents restoration from that old evidence; it does not claim thermal recovery or terminally retire the incident. A later newer full-wake/non-visible event may show it again after the Mac's confirmation delay. Only such new evidence can remove this suppression. Unknown evidence neither refreshes nor resolves it.

Retain wire kind `lid_awake`, delivery kind, notification channel ID and saved incident key for compatibility. Add optional event `awakeContext: lid_closed|screen_off`; absence means legacy lid_closed, malformed values fail validation. Add snapshot `mac.awakeContext: normal|lid_closed|screen_off|unknown` derived from the same evidence. Android must stop rejecting every lid_awake event solely because the physical lid is open. A legacy open-lid snapshot can still resolve a legacy closed-lid incident, but cannot by itself resolve a screen-off incident.

## Phone freshness, history and dismissal

A card is live only for 180 seconds after its last authenticated full-wake/non-visible confirmation, corrected for event age. Persist a monotonic elapsed-time deadline and phone boot count; wall-clock changes cannot refresh it. Receipt time of a delayed FCM message is not fresh Mac evidence.

After that deadline, absent an accepted resolution:

- lid_closed historical title: **Your Mac was running with the lid closed**
- screen_off historical title: **Your Mac was running with the screen off**
- Body: **Last confirmed at HH:MM.** Include the date when needed for an earlier day.
- Non-ongoing, no expiry, silent, dismissible. Keep the existing Sleep now flow; it requires a currently authorized connection and never queues a power action for a future reconnect.
- Prefer updating the same tag/ID. If Android already expired the live card, publish the historical replacement quietly.

Use a process timer as a fast path, a single non-exported PendingIntent alarm as the supported process-death fallback, and reconciliation on normal app startup, package replacement and boot after unlock. Persist before scheduling. Use an inexact elapsed-realtime alarm, with no new special permission. Keep the OS-owned live-card timeout as a backstop against indefinite present-tense claims.

**Timing limit:** Android may defer the historical replacement in Doze or battery saver. The live card may disappear at its OS timeout before the historical card is posted. History remains stored and is reconciled on the next allowed execution. Do not advertise exact three-minute replacement or gap-free display under process death. Do not rely on undocumented timeout-to-deleteIntent callbacks.

Every callback validates current pairing, incident ID, latest event ID, deadline and terminal state. Old callbacks cannot downgrade newer evidence or recreate a resolved/unpaired incident. Persist historical dismissal. Live-card dismissal before its deadline acknowledges that evidence; an ambiguous deletion at/after timeout must not be treated as proof of deliberate historical dismissal. A newer fresh event can restore a live card silently; duplicate evidence cannot.

Keep transport event-expiry and replay limits intact. Within accepted freshness, aged initial events become silent history. Do not accept expired resolution packets merely to tidy notifications; a fresh authenticated snapshot may reconcile a condition it positively establishes as ended.

## Thermal episode lifecycle

Keep reading Apple's Nominal/Fair/Serious/Critical scale. Notification scope and episode recovery are separate:

1. A new episode can start during full wake if lidClosed is true, isBrewing is true, or a fresh matching native report says thermalBrewingPaused is true.
2. Once Critical starts, keep its existing incident identity despite brew stop, lid opening or scope becoming false. The native guard's intervention must not disarm the warning it caused.
3. Unknown or missing thermal data does not recover the incident.
4. A fresh Nominal/Fair/Serious reading ends Critical ringing and publishes the existing recovered presentation with that state. Noncritical guard warnings remain separately governed by native guard activity, the five-minute minimum between warnings, and the existing 30-minute phone snooze.
5. Native Critical brewing-stop behavior and native guard configuration remain unchanged. Phone Sleep now keeps its existing result flow. Confirmed Ignore silences the alarm for five minutes; it is not thermal recovery.

### Confirmed Critical sound and lost-contact behavior

The owner selected continued ringing after loss of contact until a confirmed lower thermal state or explicit Ignore. The current 90-second stale transition and OS-owned five-minute ringing cap must therefore stop acting as automatic silence/recovery mechanisms.

- Freshness still controls truthful wording. Fresh Critical uses the current Critical title; unconfirmed Critical says **Your Mac reported Critical heat** / **Last reported thermal state: Critical.** Do not display a transport-status panel on the alarm screen.
- An unresolved unsnoozed Critical episode continues its warning sound across missing readings, process loss, brewing stop and lid opening. Do not silently move it to a quiet channel or let a fixed notification timeout end the alarm. This can include a Mac that went to sleep without sending recovery; explicit Ignore remains the user's escape.
- Snooze wins over freshness: becoming stale during the five minutes must not break Ignore. At its deadline an unresolved episode rings again even without a new Mac reading. A confirmed lower state cancels both ringing and pending rearm work; old callbacks cannot restart it.
- Sound is a gentle repeated warning, not a siren, call ringtone or default alarm-clock melody. Prepare one original short two-note cue with a short pause between repetitions (approximately one pattern every four seconds), preview it for the owner before a physical alarm test, and avoid escalating volume or frequency.
- Use Android AudioAttributes.USAGE_ALARM so ordinary ringer-silent mode does not govern the warning. Respect the user's alarm-stream volume; never force maximum volume or unmute the alarm stream. Zero alarm volume, disabled channel, denied notification/full-screen access and DND remain OS-controlled and must be reported honestly.
- A dedicated versioned Critical channel is justified because Android does not let an app replace the sound of an existing channel. Leave the activity/noncritical channels and their preferences intact. New Critical channel uses the quiet warning asset, alarm audio attributes and high importance; it is still subject to the user's settings.
- Reuse existing Sleep now and confirmed Ignore actions. An unconfirmed Critical episode keeps those actions; a confirmed recovered episode keeps Sleep now/Dismiss as already designed.

For five-minute Critical snooze rearming, use one durable explicit AlarmManager PendingIntent, plus the foreground fast path and startup/boot reconciliation. On Android 12+, use setExactAndAllowWhileIdle only when SCHEDULE_EXACT_ALARM special access is allowed. Declare that user-granted access and expose one concise readiness/link in the existing alert settings; never grant it programmatically. Without it, use an inexact fallback and state that Android may delay rearming. Do not claim unrestricted exact timing in every device state, and do not request this permission for informative history.

Persist the snooze deadline before canceling sound. Use elapsed time within the same phone boot; for a previous-boot record, a still-future wall-clock remainder may be honored only within the five-minute maximum, otherwise treat it as expired. Repeated app starts must not extend Ignore. Force-stop/uninstall/revoked OS permissions remain platform limits; there is no app-owned perpetual wake lock or foreground daemon.

## Validation and delivery

Cover the complete context matrix, all 60/90/180-second boundaries, cross-context continuity, genuine-input rearming, initial already-closed wake, DarkWake, unknown topology, delayed events, stale callbacks, dismissed history, clock changes, reboot and unpairing. Thermal tests must stop brewing in the middle of Critical, persist/reload the episode, and prove only an actual lower thermal reading recovers it.

Use the emulator for real Android notification flags, quiet replacement, process loss, Doze, reboot and receiver behavior. No test may run those device mutations on the physical phone. On the owner's Mac, later validate built-in/external screen standby, monitor disconnect, real lid closure, system sleep and classification without making the recorder prevent sleep. No real Critical condition is induced.

Update both companion apps together after review, preserving pairing. Check retained Android signer and install in place. Keep one canonical Mac app. Document the Android timing limit and actual hardware verification status. This design proposes no native Keepresso patch and no change to mobile command authorization.

## Primary references

- Apple display versus computer sleep: https://support.apple.com/en-euro/guide/mac-help/mchlp1025/27/mac/27
- CoreGraphics online displays: https://developer.apple.com/documentation/coregraphics/cggetonlinedisplaylist(_:_:_:)
- CoreGraphics display sleep: https://developer.apple.com/documentation/coregraphics/cgdisplayisasleep(_:)
- Apple sleep notifications: https://developer.apple.com/library/archive/qa/qa1340/_index.html
- Android alarm scheduling and inexact delivery: https://developer.android.com/develop/background-work/services/alarms

Prepared and source-reviewed with LLM assistance. The stale-Critical and warning-tone choices were supplied by the owner during review. Hardware outcomes are not claimed from code inspection.
