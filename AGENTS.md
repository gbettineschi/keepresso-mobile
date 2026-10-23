# Keepresso Mobile

- The owner requested public visibility on 2026-10-23. Keep credentials and private setup files outside the repository; do not change visibility again or publish releases without the owner's request.
- Android app label: Keespresso. Repository: keepresso-mobile. This is an unofficial companion.
- Read docs/requirements.md and docs/protocol.md before changing shared behaviour.
- Keep the official Keepresso app unmodified. Vendored upstream source files must remain byte-identical to the pinned revision; put companion adapters outside its Sources directory.
- Never start keep-awake leases, alter the user's Keepresso settings, grant permissions, enable login items or execute sleep/power commands while developing or testing. Real power tests require the user's explicit action. Use dependency-injected fakes for mutation tests.
- Monitoring must not prevent sleep. The duplicate trigger engine runs only for a bounded, explicit refresh, never permanently.
- No Tailscale. Bluetooth is the initial transport. Internet is optional and must not be represented as implemented until tested.
- Commands require an authorized device and fresh authenticated encryption. Never retry uncertain mutation delivery or replay queued commands on reconnect.
- Preserve unknown, stale and unavailable states. Missing permissions or decode failures are not evidence of inactivity.
- Keep credentials, device records, real activity logs and local environment files out of git. Test vectors contain public deterministic fixture keys only.
- Use tests for security, framing, command freshness/deduplication, reminder behaviour and state interpretation. Do not make tests change real power state.
