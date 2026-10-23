# Keepresso Mobile: background operation

Proposed behavior for approval:

- One companion app process; no separate watcher executable.
- No menu bar icon. No Dock icon while hidden.
- Opening Keepresso Mobile shows a normal pairing/settings window. Closing that window keeps the app running quietly. Opening it again restores the window.
- An optional **Follow Keepresso** control registers the app as a macOS-managed per-user background item. It starts hidden after login. Registration is performed only when the user enables this control; development and tests do not enable it.
- The resident app watches the running-app list through event-driven observation. It does not poll for processes. This also detects native Keepresso, which is a menu bar application.
- Phone connections, reminders, timers and trigger evaluation run only while `/Applications/Keepresso.app` is running. When Keepresso exits, connections and work stop, while the app waits quietly. Opening Keepresso again resumes the saved connection choices. It never starts native Keepresso or a brewing session automatically.
- macOS restarts the managed app after a crash or a forced kill, with throttling to avoid a restart loop. **Quit Keepresso Mobile** exits successfully and is respected; the app can be reopened manually or will start at the next login. Disabling the background item in macOS is also respected.
- **Follow Keepresso** reports the actual macOS approval state and offers to open Login Items when approval is required. It is not presented as working merely because registration was requested.
- Existing device identities, pairing secrets, command journals and relay configuration remain compatible. The original Keepresso app is unmodified.
- The new Mac icon keeps the original flat ivory/copper/dark coffee-cup style and adds a small phone outline behind the cup. Android retains the original Keepresso icon.

## Approaches considered

The recommended approach is the single resident app above: it avoids a second watcher process and a separate installation lifecycle. A plain launch-at-login item is simpler but does not recover after being killed. A separate watcher that launches and terminates a full companion adds a second process and more coordination without improving this app's needs.

The managed background item uses Apple's Service Management API and a bundled per-user launch-agent definition. It does not install a root daemon, modify native Keepresso, or grant itself permission to prevent sleep.

## Verification

Use injected/fake lifecycle inputs to verify cold start, native Keepresso launch/exit/relaunch, duplicate events, stale asynchronous work, and preserving enabled connection choices. Build and inspect the bundle, background-item definition and icon. Actual background-item registration, launch after login, crash restart and physical phone reconnection require the user's device acceptance test; they are not enabled or simulated as proven during development.
