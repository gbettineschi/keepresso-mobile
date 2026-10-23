# Keepresso Mobile wire protocol v1

This file is the shared contract for Swift and Kotlin implementations. UUIDs are canonical lowercase strings. Binary values use standard padded Base64. UTF-8 strings below use literal LF separators and no trailing LF. Never log proofs, secrets or ciphertext plaintext.

## BLE framing

Service UUID `73f8d1c0-823f-4c2f-9e0a-4454129f3001`.
Input characteristic `73f8d1c0-823f-4c2f-9e0a-4454129f3002` supports writes with response. Output characteristic `73f8d1c0-823f-4c2f-9e0a-4454129f3003` supports notifications. Android subscribes before sending a record. No OS bonding or encryption-required attribute is requested; application encryption is mandatory for private messages.

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

Response: `{type:"response",id,status:"ok"|"error"|"uncertain",message?:<safe-user-text>,snapshot?:<Snapshot>}`. A delivered command is not an executed/acknowledged command. Connection loss after send becomes uncertain for mutations. Never automatically resend mutations. A repeated mutation ID returns its stored outcome (or uncertain), not another execution. Bind ID reservation to authorized device and request-body fingerprint; reserve durably before side effects. Reject mismatched duplicate bodies.

Server may send `{type:"event",event:{id,kind,createdAt,title,body,scheduledEnd?:<ISO8601>,snoozedUntil?:<ISO8601>}}` after authentication. Kinds: `hourly`, `session_ended_awake`, `battery`, `thermal`, `sleep_failed`. Android notification actions issue authenticated commands only while reachable, otherwise open the app with no queued power action.

## Snapshot

All timestamps ISO8601 UTC. Missing/null values mean unknown; no defaults implying safety.

```
{
  capturedAt, macName,
  mac: { lock: "locked|unlocked|unknown", display: "on|dimmed|off|unknown",
    lid: "open|closed|unknown", batteryPercent: number|null,
    powerSource: "battery|ac|unknown", temperatureC: number|null,
    temperatureSensor: string|null, thermal: "normal|warm|hot|unknown" },
  keepresso: { appRunning: boolean, version: string|null, isActive: boolean|null,
    endsAt: string|null, triggersEnabled: boolean|null, triggersPaused: boolean|null,
    sessionKind: "manual|automatic|lease|unknown", safetyPause: "battery|thermal|none|unknown" },
  capabilities: { startManual, stopManual, pauseTriggers, resumeTriggers, sleepNow, refreshTriggers },
  triggers: { state: "not_checked|checking|ready|unknown|stale|error", checkedAt: string|null,
    combined: boolean|null, rules: [{ id, label, satisfied: boolean|null,
      inGrace: boolean, graceRemaining: number|null,
      details: [{label,active,agent:string|null}] }], message: string|null },
  reminders: { enabled: boolean, intervalSeconds: 3600|7200, snoozedUntil: string|null,
    endedAwakeDelaySeconds: 120|300|600 }
}
```

Reachability is derived by Android from authenticated fresh responses and transport state, not a remote claimed awake field. After disconnect show Unreachable and last-known readings, disable mutations. Mark snapshots stale after 15 s without an authenticated update.

Triggers always represent an independent snapshot. A successfully completed, structurally valid assessment replaces checkedAt, including a partial assessment with unknown per-rule inputs. Such a partial assessment uses state unknown and an explicit message; the phone labels it Some inputs unknown, rather than Stale. Worker timeout, parse failure or incompatible settings preserve the previous successful timestamp and mark stale/unknown as appropriate. Never advertise observer-only grace as a guarantee of native handover. A native status/mode/setting change makes the old preview stale.
