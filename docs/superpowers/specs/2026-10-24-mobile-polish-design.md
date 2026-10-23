# Keepresso Mobile refinement

The owner requested implementation and emulator verification of the following
refinements, retaining the current apps, pairing and unmodified upstream app.
This checklist is the work ledger; no item is complete without recorded evidence.

| ID | Requested outcome | Verification / status |
|---|---|---|
| 01 | Android launcher/header/settings name: Keepresso Mobile | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 02 | Remove bold power-source detail | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 03 | Real Celsius reading where readable; no Normal/Sensor unavailable text | Verified: 57 Swift tests; live read-only CPU temperature; generic worker error and retained assessment |
| 04 | Compact battery: percent, charging indicator; amber ≤20%, red ≤10% | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 05 | Temperature neutral/amber/red using system thermal pressure; no invented universal temperature limits | Verified: 57 Swift tests; live read-only CPU temperature; generic worker error and retained assessment |
| 06 | Technical trigger-worker errors logged; concise user error | Verified: 57 Swift tests; live read-only CPU temperature; generic worker error and retained assessment |
| 07 | Configured trigger names only, native-style tick/circle; no agent/session details | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 08 | Quick ordinary status; heavier trigger assessment stays explicit and bounded | Pending |
| 09 | Active triggers, checked time and Check on one line | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 10 | Remove Unknown/input unavailable prose without treating unknown as inactive | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 11 | No disabled-button flicker from polling; bounded in-memory command wait behind a read | Pending |
| 12 | Measure Bluetooth and live Vercel latency; test duplicates/failover; state physical gaps honestly | Pending |
| 13 | Compact duration stepper, fixed-width duration and Start, space between controls | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 14 | Implement safe Sleep now rather than hardcoded unavailable | Pending |
| 15 | Remove Checking Mac and other transient read boilerplate | Pending |
| 16 | Native vs helper reminder responsibilities, no duplicate routine notification owners | Pending |
| 17 | One lid-close warning: Mac sound plus best-effort haptic and phone warning | Pending |
| 18 | Strong Android warning channel: sound/vibration, DND setup and truthful limits | Pending |
| 19 | Closed-lid native menu icon suggestion, no fork or unsolicited upstream post | Pending |
| 20 | Polished Settings with compact grouped controls and useful setup/status | UI verified: five emulator tests in light and dark; backend dependencies tracked separately |
| 21 | Emulator light/dark and failure-state verification; retained-key app updates | Pending |

## Approach

Keep native Keepresso responsible for sessions, trigger rules, battery/thermal
protection and its optional local reminders/end actions. The companion owns
mobile delivery and the missing lid-close cue. Avoid a fork, permanent duplicate
trigger engine, extra service or additional device pairing.

Ordinary status will poll every two seconds over Bluetooth while the dashboard
is open, ten seconds otherwise. Keep internet polling at five seconds to retain
the established free-tier budget. Remote commands will still have polling delay;
measure it instead of claiming instant delivery. Trigger assessment remains a
separate explicit Check, with its own timestamp. Top refresh updates ordinary
status. Unknown rules use a neutral question-mark circle, not a false inactive
tick or explanatory paragraph. Screen-reader descriptions retain the meaning.

Read-only requests must not mark the whole UI busy. A user command can wait
briefly behind a read in memory, but is dropped if the connection changes,
freshness is lost, the app closes, or its short wait expires. Never resend an
already submitted mutation or queue a power action across reconnect.

Battery uses percent and an unobtrusive charging/plug icon. Charging is distinct
from being connected to power. Temperature uses an existing read-only Keepresso
sensor backend, with a documented chosen CPU sensor/group; keep a dash if no
honest reading is available. Thermal severity follows macOS pressure. Diagnostic
sensor identity stays in logs/settings, not under the dashboard number.

Sleep will stop/pause the native hold using the supported stop URL, verify that
state, wait for Only while brewing to release its sleep override, then issue one
normal system sleep request. Never claim disconnection proves sleep. A manually
latched global sleep override or unknown release must produce a specific concise
failure instead of overriding an unrelated privileged setting. Tests inject all
power operations; the owner performs the physical sleep acceptance step.

## Reminders

Keep three useful companion alerts: lid closed and still held awake (once per
closure), periodic still brewing (hour/2h/off, OK, Snooze 6h), and session ended
but continuously awake (after selected grace). Thermal incidents remain safety
warnings. Routine snooze does not suppress lid/safety warnings. Unknown/offline
intervals cannot prove a lid event or continuous wakefulness; avoid false alerts
on restart and deduplicate one event ID across Bluetooth and internet.

The owner selected **Mac sound + phone notification**, then requested Mac haptic
feedback and the strongest permitted phone warning. Mac haptics are trackpad
feedback, often suppressed without touch, not a body vibration motor. Android
gets a dedicated high-importance alarm-audio/vibration channel with explicit
system settings/DND exception setup. Neither OS guarantees sound against all
mute, volume, Focus/DND, permission, hardware and delivery conditions. Do not
silently change system volume or DND policy. No real-device permission grants or
test sounds/vibrations/power commands during development.

Settings groups: connected Mac/transport; routine reminders; warning delivery and
Android notification setup; authorization removal. Hide implementation details
from the main dashboard. Prepare a concise upstream icon suggestion locally;
posting it requires an explicit request to send it.

## Alternatives considered

- Frequent trigger re-evaluation would unify timestamps, but duplicates native
  monitoring and violates the accepted bounded-engine design. Retain Check.
- Faster permanent internet polling would reduce latency but risks free quotas.
  Keep five seconds; improve response flushing and foreground waiting where safe.
- A privileged companion daemon could forcibly clear global sleep settings, but
  adds installation/authorization and ownership hazards. Use verified native stop
  plus normal system sleep, reporting actual blockers.
