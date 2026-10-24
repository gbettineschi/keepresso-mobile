# Internet fallback implementation

Authorized by owner request to implement secure Vercel fallback preserving pairing. Continue the existing dedicated feature branch/private draft PR. Contract: docs/relay-protocol.md; native power actions remain fake in tests.

1. Shared fixtures: independent Node AES-GCM/HKDF vector, strict envelope validation and ID/body binding tests.
2. Backend: Vercel Node endpoint, Firestore durable adapter, FCM sender, strict role boundaries, idempotent immutable records, bounded expiry/queue. Test against injected durable store then actual Firestore emulator/cloud when account is available. Deny-all client rules and private setup script/docs.
3. Mac: relay envelope codec/HTTP client; Keychain configuration; existing-device enrollment; encrypted nearby configuration; shared executor+operation lookup; local revocation tombstones; epoch fencing; bounded polling/status; durable event outbox. Swift tests no real power/BLE.
4. Android: envelope codec/HTTP+FCM; preserve existing credential; nearby-first coordinator; persistent pending mutation + read-only reconciliation and event dedup; foreground polling, background push, stale/epoch checks; UI connection and setup limitations. JVM tests then Android SDK build/lint.
5. Integration: cross-language vectors; duplicate submission/handoff, relay tampering, expired queued actions, restart recovery, revocation and old snapshot tests; build both apps. Deploy to free scoped Vercel after Firebase setup, verify authentication and encrypted roundtrip through live service with fixture Mac/phone (no native mutations), measure warm/cold request latency and update budget with measured invocation duration.
6. Review and fix security findings, CI, update acceptance/docs/private PR and deliver tested artifacts. Mark physical phone/closed-lid push tests pending until actually exercised.
