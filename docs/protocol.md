# Keepresso Mobile wire protocol v1

This file is the shared contract for Swift and Kotlin implementations. UUIDs are canonical lowercase strings. Binary values use standard padded Base64. UTF-8 strings below use literal LF separators and no trailing LF. Never log proofs, secrets or ciphertext plaintext.

## BLE framing

Physical transport v2 (both apps 0.5.0+): Android advertises service `73f8d1c0-823f-4c2f-9e0a-4454129f3101`; the Mac connects as central. Phone → Mac characteristic `73f8d1c0-823f-4c2f-9e0a-4454129f3102` notifies with CCCD. Mac → phone characteristic `73f8d1c0-823f-4c2f-9e0a-4454129f3103` supports writes with response. Mac subscribes before the phone sends its pair/hello record. The phone remains the logical authentication client and the Mac the command server. One GATT operation is in flight per direction; bounded queues are discarded on disconnect. The separate v2 UUIDs prevent old scanners from connecting to the reversed service; update both apps together. Existing pairing and crypto/framing version1 stay unchanged. No OS bonding or encryption-required attribute is requested; application encryption is mandatory for private messages.

Each logical record is 4-byte unsigned big-endian length followed by UTF-8 JSON, maximum 65536 bytes. A transport chunk may split anywhere, including inside the length prefix. Bound aggregate receive buffers, partial-frame lifetime (10 s), pending handshakes (4), notification queues and malformed-input attempts. Serialize GATT writes; respect negotiated write size and Mac notification backpressure.

## Pair invitation and authorization

QR is `keespresso://pair?v=1&mac=<macUUID>&token=<standard-base64-percent-encoded-32-bytes>&expires=<unix-seconds>&name=<percent-encoded-name>`.

The v1 invitation scheme retains its original spelling for compatibility with already installed phones. The product name is **Keepresso**; branding changes do not change pairing keys or the wire protocol.
The token is valid for 300 seconds on the Mac, one successful approval only. Device names are <=80 UTF-8 bytes. IDs and nonces have strict length/format validation before use.

Phone sends `{type:"pair",version:1,macId,deviceId,deviceName,clientNonce,proof}`.
Pair transcript = `keepresso-mobile/pair/v1\n<macId>\n<deviceId>\n<clientNonce>\n<base64 UTF-8 deviceName>`.
Proof = HMAC-SHA256(invitationToken, UTF8(pair transcript)). Verify with constant-time comparison. Invalid requests reveal no private state.

Mac shows a pending request and needs local owner approval; it may send `{type:"pair_pending"}`. On approval, consume the invitation and derive:
`deviceKey = HKDF-SHA256(IKM: token, salt: SHA256(UTF8(macId + "\n" + deviceId)), info: UTF8("keepresso-mobile/v1/device-key"), length:32)`.
Store deviceKey securely on both devices. Mac returns `{type:"paired",macId,deviceId,proof}` where proof = HMAC-SHA256(deviceKey, UTF8(`paired\n<macId>\n<deviceId>`)). Phone verifies before persisting. Approval timeout/denial returns `{type:"pair_denied"}`. After approval, run the regular handshake; pair approval alone never permits plaintext controls.

## Authenticated sessions

1. Phone -> `{type:"hello",version:1,macId,deviceId,clientNonce}` (32 random bytes).
2. Mac -> `{type:"challenge",serverNonce,proof}` (32 fresh random bytes).
3. Phone -> `{type:"authenticate",proof}`.

Transcript = `keepresso-mobile/v1\n<macId>\n<deviceId>\n<clientNonce>\n<serverNonce>`.
Server proof = HMAC-SHA256(deviceKey, UTF8("server\n" + transcript)). Client proof uses `client\n`. Derive each direction's 32-byte key using HKDF-SHA256(deviceKey, salt: SHA256(UTF8(transcript)), info: UTF8(`keepresso-mobile/v1/c2s`) or `keepresso-mobile/v1/s2c`).

Each direction starts sequence 0 and increments only after successful seal/open. Record = `{type:"sealed",sequence:<integer>,ciphertext:<base64 ciphertext || 16-byte GCM tag>}`.
Nonce = four zero bytes || 8-byte big-endian sequence. AAD = UTF8("keepresso-mobile/v1"). Sequence must equal the receiver's next value, range 0...2147483647; close/rekey at exhaustion. A failed authentication or parse closes the session; never increment a counter and keep processing corrupt messages. Keys are unique per random handshake and direction. Reconnect never reuses nonce pairs or encrypted records.

First encrypted server message: `{type:"ready",macId,deviceId,serverTime:<ISO8601 UTC>}`. No private status before completed client authentication.

## Requests and responses

Encrypted request:
`{type:"request",id:<UUID>,action:<name>,issuedAt:<ISO8601 UTC>,expiresAt:<ISO8601 UTC>,durationMinutes?:<int>,durationSeconds?:<int>}`.

Actions: `status`, `refresh_triggers`, `start_manual`, `stop_manual`, `pause_triggers`, `resume_triggers`, `sleep_now`, `snooze_reminders`, `resume_reminders`, `ack_reminder`, `set_reminder_settings`.
Maximum validity 30 s; issuedAt cannot be >10 s ahead of Mac clock. Phone uses ready.serverTime to compensate clock offset. start_manual accepts 15...10080 minutes in 15-minute steps. Snooze is exactly 21600 s. set_reminder_settings carries reminderSettings:{enabled:boolean,intervalSeconds:3600|7200,endedAwakeDelaySeconds:120|300|600}; all three fields are required and persisted atomically. enabled controls routine reminders only; safety/still-awake warnings remain enabled. No shell commands, arbitrary URLs or arbitrary executables are accepted from the phone.

Response: `{type:"response",id,status:"ok"|"error"|"uncertain",message?:<safe-user-text>,sleepOutcome?:"going_to_sleep|could_not_sleep|could_not_request_sleep",snapshot?:<Snapshot>}`. A delivered command is not an executed/acknowledged command. Connection loss after send becomes uncertain for mutations. Never automatically resend mutations. A repeated mutation ID returns its stored outcome (or uncertain), not another execution. Bind ID reservation to authorized device and request-body fingerprint; reserve durably before side effects. Reject mismatched duplicate bodies.

Server may send `{type:"event",event:{id,kind,createdAt,title,body,scheduledEnd?:<ISO8601>,snoozedUntil?:<ISO8601>,thermalSeverity?:"serious|critical",thermalState?:"nominal|fair|serious|critical|unknown",incidentId?:<UUID>,alertPhase?:"active|updated|resolved"}}` after authentication. Kinds include `unattended_brew`, `thermal` and `lid_awake`. Older clients may receive the legacy `hourly`, `session_ended_awake`, `battery` and `sleep_failed` events. On thermal events, `thermalState` is the actual macOS thermal state. For compatibility, `thermalSeverity: "serious"` identifies a noncritical notification from the configured native guard, including a guard set to Fair. New Critical and closed-lid events have an incident UUID. Each transition or freshness update has its own delivery UUID. A Critical recovery sets `alertPhase: "resolved"` with the current noncritical macOS state. Closed-lid status updates replace the same phone card and resolve on reopening or sleep. Updates refresh evidence without sounding another warning. Android notification actions issue authenticated commands only while reachable, otherwise open the app with no queued power action. Android's 30-minute thermal-guard snooze applies on that phone.

The companion reads guard activity from the current native Keepresso process’s local `status.json`. The optional top-level keys are `thermalState` (the same macOS scale), `thermalGuardActive`, and `thermalBrewingPaused`. A positive guard or pause report must match the current macOS state and have a recent `writtenAt`. The native status also supplies `wakeState`, `brewingStartedAt`, `brewingMode`, `returnsToAutomatic` and `lastUserInputAt`. Keepresso adjusts the last input time for its own simulated activity. Alert production requires confirmed full wake. A missing or unknown wake verdict suppresses new alerts.

Native builds that advertise `supportsTriggerModeControl` in their local status can switch Automatic and Manual through a one-use request file. The helper writes a short-lived ticket for the current Keepresso PID after checking phone authorization. The local URL carries only the ticket ID. The helper confirms the new mode using the matching `lastTriggerModeRequestID` in fresh native status. Older builds can use the supported Accessibility controls when those controls are exposed.

## Snapshot

All timestamps are ISO 8601 UTC. Missing or null values mean unknown. `thermalSeverity` uses Apple’s thermal scale. `thermalGuardActive` tells whether native Keepresso’s guard is acting. Its absence means the native app did not report that information. `thermal` and null legacy temperature fields are sent for older clients.

```
{
  capturedAt, macName,
  mac: { lock: "locked|unlocked|unknown", display: "on|dimmed|off|unknown",
    lid: "open|closed|unknown", wakeState?: "full|dark|unknown", batteryPercent: number|null,
    powerSource: "battery|ac|unknown", isCharging?: boolean|null,
    thermalSeverity?: "nominal|fair|serious|critical|unknown", thermalGuardActive?: boolean,
    thermal: "normal|warm|hot|unknown", modelIdentifier?: string,
    internet?: "online|offline|check_failed|checking|unknown",
    internetCheckedAt?: string|null,
    networkType?: "wifi|ethernet|cellular|other|none|unknown", wifiName?: string|null },
  keepresso: { appRunning: boolean, version: string|null, isActive: boolean|null,
    endsAt: string|null, triggersEnabled: boolean|null, triggersPaused: boolean|null,
    sessionKind: "manual|automatic|lease|unknown", safetyPause: "battery|thermal|none|unknown" },
  capabilities: { startManual, stopManual, pauseTriggers, resumeTriggers, sleepNow, refreshTriggers },
  triggers: { state: "not_checked|checking|ready|unknown|stale|error", checkedAt: string|null,
    combined: boolean|null, rules: [{ id, label, satisfied: boolean|null,
      inGrace: boolean, graceRemaining: number|null,
      details: [{label,active,agent:string|null}] }], message: string|null,
    checking?: boolean, outdated?: boolean, checkError?: string|null },
  reminders: { enabled: boolean, intervalSeconds: 3600|7200, snoozedUntil: string|null,
    endedAwakeDelaySeconds: 120|300|600 }
}
```

Trigger assessments are historical results of `refresh_triggers` requests. Android requests one check per foreground visit after authenticated status confirms support. The Check button requests additional checks. Ordinary telemetry never executes the assessment. After a completed result, polling and route/brewing changes preserve rows, verdicts and `checkedAt`; failed or cancelled checks also retain it. A successful check replaces the assessment, including partial unknown inputs or an empty rule list. Optional `checking`, `outdated` and `checkError` describe progress, changed rule/native context and the latest failed attempt separately from `state`, which describes the completed assessment quality. Old peers may omit these fields. Android commits a matching check answer separately from live snapshot capture ordering.

The engine watchdog remains eight seconds; the parent allows twelve seconds for process startup and bounded execution. A relay check runs as a cancellable read while lightweight telemetry continues, one per device and at most eight in total. Its deadline is the earlier of request expiry and fourteen seconds after acceptance. Matching in-flight duplicates do not execute twice; competing reads are rejected without queuing. Stop, revocation or epoch changes cancel jobs and discard late answers. The phone allows twenty-five seconds for the explicit request; authentication freshness and request validity remain unchanged.

Android derives reachability from fresh authenticated responses and transport state. Mark snapshots stale after 15 s without an authenticated update. On loss of fresh status, disable mutations and mark retained readings as last known immediately. The dashboard shows Updating for six seconds before showing Unreachable. Recovery is shown as soon as a fresh response arrives.

An isolated internet read/transport failure does not erase existing proof before that same 15-second limit; it never advances evidence timestamps. Authentication rejection or invalid payloads immediately invalidate the route. Within one authenticated relay epoch, a delayed snapshot or status response cannot move the capture timestamp backwards. A new epoch still requires a new status round trip. Machine sleep discards nearby channels, renews relay authority and permanently invalidates in-flight command authorization; wake rebuilds the nearby service and requires a fresh handshake.

Internet telemetry describes the **Mac**, independently of the phone's internet and BLE/relay transport. Online requires a fresh HTTPS 204 response from a credential-free, uncached HEAD request to `https://www.gstatic.com/generate_204`, with `https://cp.cloudflare.com/generate_204` as an independent fallback. Redirects and unexpected responses fail; each request has a three-second resource budget. Offline means no usable network path; Check failed means a path exists but neither endpoint passed (an endpoint outage/filter can also cause this). This checks usable public HTTPS, not every website, VPN route, or relay health. The hosts receive the Mac's public connection metadata, never pairing keys or application payloads.

Checks coalesce, run on path changes or when requested snapshots are due (15 seconds after the last result), and expire after 45 seconds. No additional polling timer or wake assertion. Network changes, stopping the monitor and sleep/wake invalidate old results and late completions. Android additionally rejects stale/future internet evidence using authenticated server time. Missing new fields from older helpers display Not checked/Unknown. Unreachable readings remain explicitly last-known.

wifiName is only the current associated CoreWLAN SSID (up to 128 UTF-8 bytes to accommodate conversion from legacy SSID encodings); null is not evidence of disconnected Wi-Fi. macOS can require optional Location permission, requested only by foreground guided Mac setup. No coordinates, saved-network inference or Wi-Fi scans. Network type describes the active path, or an associated Wi-Fi network when no route exists and its name can be read.

Triggers always represent an independent snapshot. A successfully completed, structurally valid assessment replaces checkedAt, including a partial assessment with unknown per-rule inputs. Such a partial assessment uses state unknown and an explicit message; the phone preserves unknown rows with an accessible question indicator. Worker timeout, parse failure or incompatible settings preserve the previous successful timestamp and mark stale/unknown as appropriate. Never advertise observer-only grace as a guarantee of native handover. A native status/mode/setting change makes the old preview stale.

## iroh and direct push

The same authenticated application protocol now runs over iroh; pairing is unchanged. Configuration enrollment, push registration and route rules are specified in [internet-protocol.md](internet-protocol.md). The old relay epoch language above remains applicable only to legacy bootstrap.
