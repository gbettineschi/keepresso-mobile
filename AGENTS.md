# Keepresso Mobile

- The owner requested public visibility on 2026-10-23. Keep credentials and private setup files outside the repository; do not change visibility again or publish releases without the owner's request.
- Android and Mac companion label: Keepresso Mobile. Repository: keepresso-mobile. This is an unofficial companion.
- Read docs/requirements.md and docs/protocol.md before changing shared behaviour.
- Keep the official Keepresso app unmodified. Vendored upstream source files must remain byte-identical to the pinned revision; put companion adapters outside its Sources directory.
- Never start keep-awake leases, alter the user's Keepresso settings, grant permissions or execute sleep/power commands while developing or testing. Use dependency-injected fakes for login-item and other mutation tests. Real power tests require the user's explicit action.
- Monitoring must not prevent sleep. The duplicate trigger engine runs only for a bounded, explicit refresh, never permanently.
- No Tailscale. Bluetooth is the initial transport. Internet is optional and must not be represented as implemented until tested.
- Commands require an authorized device and fresh authenticated encryption. Never retry uncertain mutation delivery or replay queued commands on reconnect.
- Preserve unknown, stale and unavailable states. Missing permissions or decode failures are not evidence of inactivity.
- Keep credentials, device records, real activity logs and local environment files out of git. Test vectors contain public deterministic fixture keys only.
- Use tests for security, framing, command freshness/deduplication, reminder behaviour and state interpretation. Do not make tests change real power state.

## Owner trial installations and updates

- Canonical installed companion: `/Applications/Keepresso Mobile.app`. Keep official `/Applications/Keepresso.app` separate and unchanged. Do not install or run duplicate loose companion bundles in Downloads, outputs or work folders.
- For a requested trial update, verify the package first, quit the installed companion gracefully, replace the same canonical bundle, register/reopen that path, and verify its version and saved settings. Preserve bundle ID, Keychain service, defaults, Application Support and pairing protocol. Do not clear credentials or data or grant permissions.
- Owner instruction, 24 October 2026: production startup registration and a bounded repair of a positively identified stale registration are automatic, replacing the earlier owner-click Enable/Refresh Follow flow. Opening the canonical production app may perform this setup. Never override `requiresApproval` (also used when consent is revoked), repeatedly reregister, approve macOS/Keychain prompts, or mutate real login items from tests. Settings expose only Open Login Items and an honest blocked/approval warning.
- Keep temporary unpacked bundles in hidden staging and remove them after installation. Distribute ZIP archives; remove/unregister leftover companion copies individually rather than resetting all Launch Services. Old copies go to Trash, not permanent deletion.
- Android trials keep the same package and retained signing identity, increase versionCode, and use `adb install -r` on the explicitly selected authorized phone. Verify installed version afterward. Never uninstall/clear app data to work around a signing mismatch without the owner's explicit choice.
