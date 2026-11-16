# Keepresso Mobile — iroh and direct Firebase notifications

Date: 30 October 2026.

Status: architecture and detailed design approved by the owner in chat on 30 October 2026. Production integration is now in progress; cloud retirement remains gated on replacement acceptance.

## Intent and approved direction

Make the existing Android and Mac companion communicate over the Internet without an owner-operated Vercel relay or Firestore mailbox. Keep nearby Bluetooth, the existing phone authorization, the dashboard, explicit trigger checks, reminders and acknowledged controls. The owner chose iroh plus Firebase notifications sent by the Mac, rather than retaining the current notification relay during the whole integration.

The official Keepresso app and its pinned source remain unchanged. No Tailscale, paid Apple membership, Cloud Functions, new keep-awake assertion or automatic remote wake is introduced. Keep Firebase on the owner's existing project and no-billing configuration. Cloud cleanup follows successful replacement testing; deleting the Firebase project would break notifications and is outside the migration.

## Approaches considered

1. Add iroh for foreground traffic while retaining the existing Vercel/Firestore/FCM notification path. This reduces the first change but leaves the hosting and recovery complexity the owner wants removed.
2. Use iroh for application traffic and send encrypted notifications directly from the Mac through Firebase Cloud Messaging. This removes Vercel and Firestore from the working product but requires local sender credentials, push-token enrollment and background-delivery tests. **Selected by the owner.**

The builder may use the existing deployment for bounded migration/bootstrap and rollback while both app updates are verified. It is not a permanent dependency of the selected architecture.

## Evidence and current boundaries

The isolated iroh 1.2.0 trial passed 36 real-phone checks and 18 emulator checks, covering authenticated synthetic traffic, direct/relay paths, reconnects and rejection cases. It did not integrate production credentials, real readings, command execution, notifications, endpoint discovery after restart, live handover or sleep/wake. See experiments/iroh/PHYSICAL_RESULTS.md. USB did not carry the trial protocol.

Production currently uses a Kotlin Android service with BLE and foreground HTTPS polling, a Swift BLE command server, a shared durable mutation journal and Vercel/Firestore-backed event delivery. Android's existing FCM handler decrypts authenticated event envelopes and shares durable event claims with nearby delivery. Preserve those security properties; do not replace them with possession of an iroh identifier or FCM token.

The tested Swift prebuilt iroh 1.2.0 package requires macOS 14.5+ and its Mac binary is Apple silicon only. The first integration build targets the owner's supported Apple silicon Mac and S23. This is a proposed builder choice, not an already-approved change to public platform support. General release is gated on either verified Intel packaging or an explicit, documented support decision. Android's minimum OS remains unchanged; align Kotlin and Compose plugins with the tested 2.2.21 toolchain only as needed by the binding.

## Connection and authorization

Keep BLE preferred whenever it has a fresh authenticated session. When BLE is unavailable, use one logical iroh connection. iroh chooses a direct IP route where possible and an encrypted relay route otherwise; this does not require a common Wi-Fi network. Use its tested native concurrent Router and normal public infrastructure. Public relays and lookup infrastructure are external dependencies, not an owner-hosted server and not authorization authorities.

Use the existing length-prefixed JSON framing, device-key handshake, separate directional authenticated encryption and request validation over iroh. Production ALPN is keepresso-mobile/iroh/1, separate from the throwaway trial. Each transport performs its own fresh handshake and has its own sequence counters. Never share a cipher instance or encrypted record across BLE and iroh.

The Mac generates and privately stores an independent persistent iroh endpoint secret. Do not derive the Mac's private identity from one phone's shared pairing key. The phone stores its own endpoint secret and learned Mac endpoint identity in Keystore-wrapped state. No secret, endpoint ticket containing local addresses, registration token or real activity log belongs in git.

An authorized phone learns the stable Mac endpoint identity through an encrypted configuration message over its existing BLE session. During migration, an authenticated legacy relay response may carry the same configuration. Existing pairing keys, IDs, Keystore alias, bundle ID and invitation scheme stay valid. No new QR scan or Mac authorization is required for an existing authorized device. A phone that has not received the new configuration can still reconnect nearby; do not retire the old remote path before the owner's phone has learned the identity.

Store only canonical SDK-validated endpoint identities as long-term addresses. Use the binding's normal lookup/publication and relay behavior to find the current endpoint after network changes. Prove a dial from stable identity without a runner-injected ticket before claiming this works. Lookup failure yields Unreachable; it does not authorize an unpinned endpoint or fall back to plaintext. If explicit routing hints are required by the binding, they must be authenticated, bounded and validated, and may not introduce arbitrary HTTP endpoints or embedded credentials.

Revocation on the Mac invalidates that device on all active transports and discards its token and pending events. Leaving a publicly discoverable Mac endpoint running does not retain the revoked phone's application authority. Losing the endpoint seed must not clear phone authorization: recover through an authenticated existing path and enroll the replacement address.

## Commands, freshness and connection changes

All transports call the same application command handler and durable mutation journal. Retain device-bound request IDs, request-body fingerprints, reservation before side effects, expiry validation and stored outcomes for exact duplicates. A command sent before a lost connection has an uncertain outcome unless an authenticated response establishes otherwise. Never automatically resend it through the replacement path.

The Android dispatcher selects one path per request. Any existing short wait for an unsent foreground command remains bounded and volatile, and is invalidated by route/session changes. There is no durable power-command queue. Read-only status may restart after a failed path; mutation delivery may not be guessed from transport acknowledgement or a disconnect.

Keep the 15-second authenticated freshness limit. A new route requires a fresh application handshake and status proof before controls are enabled. A failure on one route does not erase a still-valid proof on another. Late snapshots cannot move the dashboard's capture time backwards or replace a completed trigger assessment. Trigger checks remain explicit, preserve their last successful result, and use the existing bounded observer.

Ordinary foreground status stays approximately as responsive as the existing two-second nearby polling. Use bounded reconnect backoff and jitter rather than tight retry loops. Maintain one command sender and explicit session generations; late work from a closed generation cannot execute or update the UI. Mac lifecycle follows native Keepresso, closes transports on sleep/stop and rebuilds them with fresh authority on wake. Monitoring must not prevent sleep.

Retain the protocol's 65,536-byte record limit and ten-second partial-record deadline. Bound pre-authentication work to four pending sessions with a ten-second application handshake deadline. Support at most eight authenticated iroh sessions, one data stream per connection. Close idle application sessions after twenty seconds without valid traffic. Extra streams, malformed records and unauthorized peers are refused. These are proposed builder limits and must be tested under concurrent reconnects.

## Direct Firebase notifications

The Mac becomes the trusted FCM sender. Import a service-account credential into the same validated, owner-only local-storage boundary used for companion secrets, with atomic writes and no symlink or permission fallback. Keep the sender credential separate from pairing records and never send it to Android. Prefer a dedicated account with only the permissions needed to send FCM messages; replacing the credential must not reset pairing or endpoint identity.

Use the official FCM HTTP v1 interface and short-lived OAuth access tokens with the firebase.messaging scope. Scope the sender to the configured Firebase project and Google's fixed authentication/send endpoints. Private input must not redirect credential-bearing requests to arbitrary hosts. Never log keys, access tokens, phone registration tokens or decrypted payloads. Cache access tokens until shortly before expiry; no separate always-running cloud process is needed.

Android obtains its FCM registration token using the owner's Firebase client configuration. Register the current token with the Mac only through an authenticated application session. Bind registration and acknowledgement to the device, project and a persisted monotonic token revision so an old in-flight registration cannot overwrite a newer token. Store the latest token before acknowledging the platform callback. A durable, idempotent registration worker may retry while the Mac is unavailable; this exception is for notification enrollment, never for power controls. Each attempt has a bounded lifetime and sends only the current token.

To keep self-hosting practical, public Android client configuration may be supplied by the Mac over the authenticated configuration channel rather than requiring each owner to compile a different APK. The current owner's Firebase project remains the same during migration. A future project replacement must deliberately reinitialize the Firebase client, handle any required app restart and register its new token; it must not silently clear local authorization. The exact import UI and SDK lifecycle mechanism are builder decisions to validate, not grounds to weaken credential boundaries.

The Mac sends a complete encrypted event envelope in the FCM data payload. Reuse the existing event cryptography and persisted event IDs; the receiver must validate/decrypt before displaying anything. A push is not evidence that the Mac is currently reachable and never directly executes a command. Keep existing notification actions and user-configured sound/DND permissions; FCM priority is not a promise to bypass silent mode or DND.

Use high delivery priority only for genuine user-visible reminder/warning notifications and render them promptly when received. Keep the encrypted envelope at most 3,000 UTF-8 bytes and the serialized send body at most 4,096 bytes. Truncate display text on complete UTF-8 boundaries before encryption. No fallback fetch from Vercel is allowed in the completed design. A backend acceptance response is not proof of display on the phone.

Retry transient notification-send failures with exponential backoff within the event's original five-minute expiry. Never extend an old event's validity by resealing it at a later time. An unregistered token becomes unavailable and awaits fresh enrollment rather than causing a retry storm. Use a bounded local event outbox, at most 256 pending event/device deliveries in total. Existing Android event claims deduplicate BLE and FCM delivery across app restarts, including overlap during migration.

Preserve hourly reminders, six-hour snooze, session-ended-but-awake warnings, lid-awake warnings and existing safety warnings. Cancel obsolete pending reminders after context changes or sleep, and retain the existing definition of current/last-known status. Regular status updates do not become background push traffic.

## Setup and migration UX

Keep the existing restrained Keepresso theme, dashboard layout, app identities and hidden Mac background behavior. The dashboard presents Nearby Bluetooth or Internet, not a new technical badge. Connection changes and token registration must not resize dashboard rows or briefly disable controls while authenticated freshness remains valid.

The Mac's Internet settings replace relay URL/bearer setup with connection availability and a notification-setup flow. Show Configured, Waiting for phone registration or Needs attention honestly. Do not show Notifications ready merely because a credential was imported. Reuse guided setup, explaining any necessary foreground app restart without resetting pairing or permissions.

Document a source-independent owner setup: create/use a dedicated Firebase project on the no-billing plan, enable FCM, register the Android client, import public client configuration and the private sender credential on the Mac, connect the already-authorized phone, then verify a real notification with the phone locked. No Vercel account, Firestore database, Cloud Functions or copied original backup text file is required for a fresh setup. Document key rotation, project replacement, lost endpoint identity and complete reconstruction from owner account access.

Update README, building, implemented-status, acceptance, self-hosting, recovery and quota documentation together. Keep known unsupported capabilities honest; unrelated native control, Celsius or power limitations are not solved by replacing the transport.

## Verification and retirement gates

1. Run the existing core/security suites and validate untouched upstream-source digests. Prove old credential fixtures upgrade without a new pairing or hidden data reset.
2. Test authenticated endpoint enrollment, stable-identity lookup, restart and rejection of unknown/revoked peers. Exercise malformed framing, exhaustion limits, stalled handshakes, concurrent reconnects and stale generations.
3. Use fake native actions to prove one execution of a mutation across simultaneous BLE/iroh arrivals, exact duplicates and different-body collisions. Test uncertainty after send and no replay on reconnect. No automated test may invoke real sleep or alter real Keepresso holds/settings.
4. Test token rotation, stale-registration races, retry/restart behavior, credential failure, payload budgets, expiry, repeated/overlapping BLE and push events, snooze and obsolete-event cancellation using fake clocks and a fake FCM sender.
5. Build and run emulator integration with real iroh and real app protocol, including the existing dashboard/trigger behavior. Local protocol success is not physical acceptance.
6. Only after verified packages, update the canonical Mac app and the explicitly selected phone in place using the existing identities and retained signing key. The owner handles any macOS/Android permission prompts; never grant permissions from test tooling. No duplicate Mac bundles or separate permanent diagnostic app.
7. On the real phone, verify fresh status and read-only trigger checks over BLE, Internet direct where available and forced relay; test transitions during a live session and confirm no duplicate controls with fake actions. Verify encrypted reminders with app backgrounded/phone locked, notification actions after reconnect, token recovery and Mac stop/sleep/wake. Physical lid/power actions require the owner's explicit action. Do not claim a sustained battery or reliability result from a short run.
8. Demonstrate replacement with no Vercel/Firestore traffic before retiring the old resources. Keep the Firebase project and FCM client. Inventory the exact dedicated legacy resources and update recovery/quota documentation before removing their access. Do not delete unrelated projects, archives or authorization data. Publishing a release remains a separate owner-requested action.

The installed baseline, current cloud deployment and pairing remain available until the replacement has passed the relevant gates. This design does not claim the migration is implemented.

## Primary references

- Existing application contracts: docs/requirements.md, docs/protocol.md and docs/relay-protocol.md.
- Trial evidence and dependency constraints: experiments/iroh/README.md and experiments/iroh/PHYSICAL_RESULTS.md.
- Pinned binding: https://github.com/n0-computer/iroh-ffi/releases/tag/v1.2.0
- FCM trusted sender requirements: https://firebase.google.com/docs/cloud-messaging/server-environment
- HTTP v1 authorization: https://firebase.google.com/docs/cloud-messaging/send/v1-api
- Android message priority and background handling: https://firebase.google.com/docs/cloud-messaging/android-message-priority
