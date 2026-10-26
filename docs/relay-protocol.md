# Internet relay v1

The existing owner-approved deviceKey and BLE protocol stay in place. This is an additional transport, not an additional pairing authority. No Wi-Fi transport, permanent wake assertion, or automatic mutation retry is introduced.

## Envelope contract

JSON fields: `version:1, macId, deviceId, id, epoch, direction, kind, createdAt, expiresAt, nonce, ciphertext`. IDs and epoch are canonical lowercase UUIDs. direction is `c2s` or `s2c`. kind is `command`, `response`, `state`, or `event`. Times are integer Unix seconds. Binary is standard padded Base64. Nonce is 12 random bytes; ciphertext includes the 16-byte AES-256-GCM tag. Limit encoded envelope to 65536 bytes. The exact immutable envelope must be retained for any idempotent upload retry.

Derive 32-byte keys using HKDF-SHA256(deviceKey, salt SHA256(UTF8(macId + LF + deviceId)), info UTF8(`keepresso-mobile/relay/v1/` + direction)). AAD is UTF8 of these literal LF-separated values, without trailing LF:

```
keepresso-mobile/relay/v1
macId
deviceId
id
epoch
direction
kind
createdAt decimal integer
expiresAt decimal integer
```

Phone access bearer is standard Base64 of HKDF-SHA256(deviceKey, same salt, info UTF8(`keepresso-mobile/relay/v1/phone-access`), length32). Relay receives only the lowercase hex SHA256 of the UTF8 bearer during Mac enrollment. Never upload deviceKey or encryption keys. Mac bootstrap bearer is an independent random32-byte secret in Keychain; relay gets its hash in environment configuration.

To reject unauthenticated internet noise before any billed database read, the Mac supplies an `authTicket` through encrypted BLE configuration. It is standard Base64 HMAC-SHA256(key UTF8(lowercaseHexSHA256(UTF8 Mac bootstrap bearer)), data UTF8(`keepresso-mobile/relay/v1/access-ticket` + LF + macId + LF + deviceId + LF + lowercaseHexSHA256(UTF8 phone bearer))). Phone HTTPS Authorization is `Bearer <phoneBearer>.<authTicket>`; Mac Authorization remains `Bearer <macBootstrapBearer>`. Ticket proves eligibility to attempt phone authentication, not Mac authorization; the relay still checks the enrolled device/tombstone. The server never receives the bootstrap bearer in phone traffic. Optional RELAY_MAC_ID pins a deployment to one Mac; otherwise it is a single-owner deployment with Mac IDs isolated, not a public multi-tenant service.

Valid lifetimes: command <=30s, response <=120s, state <=15s, event <=300s. Reject createdAt more than10s in the future, expired messages, wrong routing/direction/kind, malformed encoding and overlarge input. Executable commands must match the current Mac epoch; responses must match their pending request epoch. A valid event may introduce a new epoch while Android is backgrounded; it never grants reachability/control. Decrypted commands still pass existing request validation. BLE and relay feed the SAME MutationExecutor and durable journal.

State plaintext: `{type:"relay_state",epoch,revision:<nonnegative integer>,snapshot:<existing Snapshot>}`. Revisions increase within an epoch. Commands use existing exact request JSON bytes. Responses use existing response JSON; envelope ID equals request ID. Events use existing `{type:"event",event:{...}}`; envelope ID equals event ID. State IDs are random UUIDs. Do not use relay receipt time to refresh snapshot age. Require a fresh status command/response round trip before enabling remote mutations after reconnect/restart.

Mac generates a new epoch at helper start, wake and after losing relay contact for15s. Discard commands from older epochs; do not execute a backlog on reconnect. Phone gets epoch from authenticated state. Cached state alone does not establish reachability.

## HTTPS API

`POST /api/relay`, JSON, Authorization Bearer, `Content-Type: application/json`. Every operation includes macId; phone operations also deviceId. Only HTTPS is accepted by native production clients (localhost may be injected in tests). No redirects to another origin. Response `Cache-Control: no-store`. Structured errors contain no secrets or plaintext. Request maximum256KiB, batches <=16 records; at most8 paired phones. `GET /api/health` returns only version and configured availability.

Mac operations use independent bootstrap bearer:

- `enroll`: `{op,macId,deviceId,tokenHash}`. Register/update phone access hash; retain existing state/push registration for an unchanged hash. Maximum8 active devices. No phone can enroll itself.
- `revoke`: `{op,macId,deviceId}`. Tombstone immediately. Mac local authorization is authoritative even if cleanup fails.
- `sync`: `{op,macId,epoch,states?:[envelope],responses?:[envelope],events?:[envelope]}`. Each record is s2c for a currently enrolled device. State must match current epoch; immutable events/responses may retain their original epoch across reconnect, until expiry. Persist latest state and bounded expiring response/event mailboxes. Return `{commands:[envelope],retryEvents:[eventID]}` for unexpired commands matching current epoch. Responses remove matching command entries, with same device and originating epoch. Immutable ID conflicts return409. Events use durable30s FCM claim leases; retries retain the same encrypted event/ID. A transient push failure adds retryEvents without blocking command/state sync; permanently invalid registration tokens are cleared. Durable event mailbox remains available for foreground retrieval. Firebase acceptance is not phone delivery.

Phone operations use derived phone bearer:

- `poll`: `{op,macId,deviceId}` -> `{state:envelope|null,messages:[envelope]}`. Expired records omitted. Mailbox retention is bounded (32 recent records) with lazy expiry cleanup; no paid TTL dependency.
- `send`: `{op,macId,deviceId,envelope}` -> `{accepted:true}`. Only c2s command, matching IDs, fresh epoch/current Mac state. Reject stale/unreachable/old epoch with409. Bound pending queue32 perMac. HTTP acceptance does not mean execution. No automatic command retry after request submission begins.
- `push`: `{op,macId,deviceId,token:<FCM token>}` -> `{registered:true}`. This grants notification delivery only, not authorization.

Backend durable store: Firestore Standard; no public client access, deny-all security rules. Only server Admin credentials. FCM data shape `{relayEnvelope:<JSON envelope>}`; maximum ~3500 UTF8 bytes before FCM. Oversize notification envelopes remain in mailbox and send a content-free `{relayWake:"1",macId,deviceId}` hint; hints cannot directly post notifications. Do not silently accept an unavailable Firebase configuration.

## Routing and recovery

Android creates one exact request/body/ID before route selection. Persist mutation intent before submission. Select authenticated BLE if available, otherwise authenticated fresh relay. Once transmission begins never automatically retry the mutation through either route. Persist pending/uncertain outcome across app restart. Fresh read-only `operation_status` request with operationId and bodyDigest (standard Base64 SHA256 original request bytes) can reconcile the shared journal without resubmitting the operation. Add this read-only action to both native validators and executor dispatcher.

BLE server sends encrypted `{type:"relay_config",url:<HTTPS base URL>,authTicket:<Base64>,enabled:true}` after ready when enrollment succeeded. The paired phone stores URL/ticket alongside its existing credential and derives its bearer; no second QR or authorization. Disabled/unconfigured relay must not erase the existing pairing. An already paired phone receives config on its next nearby connection.

Mac sends ordinary snapshots/events over BLE when that device is authenticated nearby. On disconnect it publishes state to relay immediately and continues state every10s. Relay command poll every5s while Mac is naturally awake; no keep-awake lease. Android polls every5s only while foreground, not authenticated on BLE; after explicit command it may poll outcome at1s for at most30s. Background uses FCM. BLE permission denial does not disable internet; notifications denial does not disable foreground status.

While the phone is open over internet, a successful status round trip requests a 65-second foreground publication window (snapshots every5s). Android renews after30s from the successful response, leaving room for network delay or another pending operation. A renewal blocked behind a pending request remains due; it is never postponed as if sent. Delayed messages cannot backdate newer authenticated capture evidence within the same epoch. Transient polling failures retain only already-fresh proof; they do not extend its15s expiry. Rejected authorization or invalid payloads invalidate immediately.

Mac persists reminder outbox entries before transmission; one eventID survives handoffs. Android persists claimed event IDs before posting through BLE or FCM, bounded by expiry/time. Reject expired events and obsolete incidents when a newer authenticated snapshot proves them resolved. Outbox retries apply to immutable notifications/status only, never power commands. A local revoked-device tombstone gates every incoming and outgoing transport even if Keychain/remote deletion fails.

## Free tier model (one Mac, one phone)

Mac awake24h: 518400 five-second sync requests/30days. Phone foreground2h/day:43200 five-second polls; ~562k combined before occasional controls/events. Status writes8640/day; empty queue reads17280/day plus8640 enrolled-device validation reads/day; phone polls add at least2880 reads/day (auth/state + mailbox), approximately28800 total before occasional messages. Keep auth/state in one device document, avoid per-sync auth/heartbeat writes. Budget remains shared with other projects. Firestore free quotas are50k reads/day,20k writes/day; Vercel Hobby1M invocations/month,4 CPU-hours,360GB-hours. Latency target is seconds (poll wait0–5s + network), to measure on real deployment; not an instant delivery guarantee. No permanent Vercel WebSocket because waiting memory is billed. Measurements, not this estimate, determine actual headroom.
