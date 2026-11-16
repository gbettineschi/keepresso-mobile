# iroh sessions and direct Firebase delivery

This extends [protocol v1](protocol.md); phone pairing, device keys and request bodies remain unchanged. The [legacy relay](relay-protocol.md) is bootstrap/rollback only until acceptance.

## Transport and trust

- iroh binding1.2.0, ALPN `keepresso-mobile/iroh/1`, one bidirectional framed stream per connection.
- The Mac persists a separate random 32-byte endpoint secret. Android persists its own endpoint secret and binds learned Mac metadata to the existing macId/deviceId/device-key fingerprint.
- A long-term address is canonical padded Base64 of the SDK’s 32-byte endpoint identity. Lookup/direct routes/public relay do not authorize commands. Each route performs the full existing device-key handshake and has its own cipher and sequence counters.
- Standard record maximum 65,536 bytes; partial record timeout 10s; at most 4 pending handshakes, 10s application handshake deadline, 8 authenticated sessions and 20s without valid traffic. Extra streams invalidate the connection.
- Ordinary Internet operation acquires no awake assertion or native automation lease.
- Android shares one native endpoint across foreground and token-registration sessions. Each connection retains its own application cipher. A 15s idle grace preserves the relay route during reconnects; the endpoint closes after the last user stays absent. Native I/O runs off the Android main thread, with a separate deadline that closes stalled connections.
- Initial identity publication can briefly have no address. Android permits up to three TLS dial attempts within its 25s connection budget, before application authentication or command submission. This does not retry a power operation.

## Configuration enrollment

An authenticated `ready` may carry `internet`, or the server may send encrypted configuration separately. Status snapshots can carry `internetConfiguration` so changed public Firebase options reach a connected Internet phone too.

```json
{
  "type": "internet_config",
  "version": 1,
  "endpointId": "<canonical Base64 of 32 public bytes>",
  "firebase": {
    "projectId": "your-project-id",
    "applicationId": "1:123456:android:abcdef",
    "apiKey": "<public Android API key>",
    "senderId": "123456"
  }
}
```

`firebase` is optional. These fields are public client options, never a sender private key or phone token. Strict type/length/version/project consistency validation precedes persistence. Invalid or foreign metadata retains the last valid configuration and never changes pairing. Exact repeated metadata is idempotent and does not restart token enrollment.

BLE supplies this inside its existing encrypted session. During migration an authenticated legacy status can carry it too. Once an exact device key has authenticated over iroh, its local migration marker permits ending legacy bootstrap. Deleting the marker cannot grant authority.

## Notification registration

The phone persists a new/current token and monotonic revision before scheduling a bounded WorkManager attempt. Failed attempts remain durable and retry with linear backoff starting at30s (Android controls scheduling and caps the backoff). There is no terminal attempt-count cutoff; a newly authenticated connection also reschedules a pending revision. Token registration is authenticated maintenance, not a power command and not dependent on a fresh power-control status.

```json
{"type":"push_registration","projectId":"your-project-id","token":"<FCM token>","revision":1}
```

Success:

```json
{"type":"push_registered","projectId":"your-project-id","revision":1,"tokenHash":"<canonical Base64 SHA-256 of token UTF-8>"}
```

An unavailable/mismatched project returns `push_registration_error` with safe text. The Mac rejects lower revisions and same-revision/different-token conflicts; exact duplicates succeed. Android acknowledges only a matching current project/revision/token hash. A late token callback or old upload cannot replace a newer token. Replacing Firebase configuration does not reset phone authorization or endpoint identity. A required SDK restart is surfaced to the owner.

## Delivery and expiry

Foreground BLE/iroh sessions carry the existing encrypted `event` message. The Mac also sends the complete encrypted `RelayEnvelope` in FCM’s data field `relayEnvelope`; the field name is retained for compatibility and needs no HTTP relay. FCM priority is high for user-visible warnings/reminders; Android still controls actual presentation.

The sender uses fixed Google OAuth/FCM HTTPS endpoints, service-account RS256 credentials and the `firebase.messaging` scope. The private key remains in independent owner-only Mac storage. Envelope bytes are capped at 3,000 and the entire FCM JSON body at 4,096. Oversized text is currently rejected; automatic UTF-8-safe shortening is deferred. Built-in reminder text fits the budget.

Retries retain the same envelope and its original expiry, at most 300s. The durable queue is capped at 256 event/device deliveries. Retry transient errors with bounded backoff; block an unregistered token until updated enrollment. Resolve obsolete reminders and revoke device tokens/queued events on authorization removal. Firebase acceptance is not proof of delivery or display.

Revalidate the exact pending envelope, authorization, lifecycle generation and token before each send and after OAuth acquisition. Resolution cancels preparation before network submission; a request already submitted to Firebase cannot be recalled. Optional direct-push storage failure is reported separately and does not suppress authenticated BLE/iroh broadcasts after authoritative reminder persistence succeeds.

Android validates device-bound authenticated envelopes and original expiry before notification. BLE and FCM share durable event claims, including after process restart. No push executes a command or refreshes live Mac reachability. Normal status is not push traffic.

## Route and lifecycle rules

BLE wins while it has fresh authenticated evidence; otherwise use the logical iroh route, whose underlying IP/relay choice is internal. A new route needs a fresh handshake and successful status before mutations. Keep the 15s freshness bound; failure on one route does not erase valid proof on another.

Both paths use one dispatcher and the same Mac durable mutation journal. Sending through one path never causes automatic mutation replay on another. An uncertain outcome is reconciled with `operation_status`, not by repeating the power action. Late snapshots cannot move capture time backward or replace an explicit trigger assessment.

Sleep, native-app stop/restart and revocation invalidate old session generations. Wake rebuilds authority; no queued power command is restored. Trigger checks remain explicit, bounded and historical. Internet discovery/FCM delivery failures remain unavailable states, not evidence of sleep or inactivity.
