# Device acceptance checklist

Automated tests and successful packages do not establish physical Bluetooth delivery, macOS permissions, Android background behavior or completed sleep. Record the phone model/Android version, Mac model/macOS version, installed Keepresso version, companion commit and observed result for each test.

**Initial state:** physical-device acceptance is pending. Development verification must not issue a real sleep command, start a keep-awake hold, grant permissions or enable launch at login.

## Authorization and connection

- Start pairing locally on Mac; scan on Android; approve the correct named phone. Check that no private status appears before approval/authentication.
- Deny a phone, expire an invitation and reuse a consumed invitation. Each must fail without storing authorization.
- Try an unrelated phone/app instance without an invitation. It must not read status or control the Mac.
- Restart both apps. Saved authorization should reconnect with a new encrypted session and no replayed command.
- Revoke the phone on Mac while connected. It must disconnect immediately and fail to authenticate again until explicitly paired afresh.
- Deny Bluetooth/Nearby Devices/notification permissions individually, then grant through the normal OS UI. Confirm a usable recovery path and no misleading live state.
- Leave Bluetooth range and return. Status becomes Unreachable, controls disable, last-known readings remain distinguishable, and reconnection never executes a previously pending mutation.

## Status and trigger assessment

- Verify locked/unlocked, internal/external display on/off/dimmed, lid open/closed, battery percentage and power-source changes. Unsupported readings must say Unknown/Unavailable.
- Confirm the temperature's named sensor and severity. If no supported Celsius source exists, temperature stays unavailable; a thermal-pressure label must not imply a measured Celsius reading.
- Start/stop native manual and automatic sessions. Check Running/Not running, remaining time/Active, trigger flags and capability availability against the official app.
- Refresh triggers during both manual and automatic sessions. Check **Triggers checked at…** directly below the title. Confirm the observer stops within its budget and does not create a power hold.
- Exercise positive and negative agent, microphone and download activity. Check asynchronous warm-up, missing permissions, earlier-day timestamps and failed refreshes. Failure must preserve the previous successful timestamp and expose uncertainty.
- Check a shared-host Codex record older than ten minutes with a fresh rollout, and a stale record without one. Confirm original hook files are unchanged.
- Test a grace-only result. It must not promise that resuming native triggers will keep the Mac awake. Repeat after updating Keepresso; unsupported versions/settings must stay unavailable instead of falling back to defaults.

## Controls — deliberate power changes

Only perform these when prepared for the Mac to become unreachable. Save work first.

- Use the duration stepper and Start. Confirm the chosen duration and native paused-trigger semantics. Stop manual session and compare the observed official status.
- Resume triggers during a manual session. Confirm the handover warning, native immediate handover and no promise of automatic resume after timer expiry.
- Deny Accessibility, remove/rename an expected menu item, or expose ambiguous controls. Pause/Resume must report unavailable rather than click a guessed target.
- Interrupt the link after a mutation is sent but before acknowledgement. The phone must show an uncertain outcome; reconnect must not repeat the mutation.
- Confirm Sleep now, observing the native safety path and actual sleep separately. Disconnection is not proof of sleep. Test refusal/failure paths with unsupported global holds; do not bypass them.
- Wake the Mac manually. Confirm new status, no obsolete stopped-session warning and no replayed sleep/stop request.

## Reminders and Android background behavior

- With a live session, receive an hourly reminder while the phone is locked/screen off. Verify scheduled-end text or **No automatic end time**.
- Tap OK. The next regular reminder remains scheduled. Tap Snooze 6 hours; routine alerts pause until the displayed time, including across helper restart.
- Verify Resume reminders and the 1-hour/2-hour/off settings. Settings acknowledgement must reflect durable Mac-side state.
- End a session while the Mac remains awake. Receive one warning after the selected 2/5/10-minute delay. A new session or observed sleep before the deadline cancels it.
- Restart the helper between session end and the warning deadline; confirm correct persistence and no duplicate warning. Sleep then wake must not resurrect the old warning.
- Verify supported battery/thermal/sleep-failure warnings bypass routine snooze and are not duplicated for one incident.
- Tap notification actions after disconnect. They must not queue future Mac-control actions. Opening the app should explain reachability.
- Test Android screen off/Doze, app backgrounding, OS service termination, notification denial and closed Mac lid. Observe actual delivery and power impact; record failures explicitly.

## Outside this build

Internet delivery/relay, remote wake, official app trigger-state restoration, Play Store release, notarized Mac distribution and an independent security audit are not completed by these tests.
# Internet transport acceptance

These are additional to the nearby checks below. Keep all real power changes owner-initiated; no development test may start Keepresso or put the Mac to sleep.

- Deploy to the owner's own free Vercel/Firebase project; verify401 for unauthorized callers, deny-all direct Firestore access, no public source/secret files, and a synthetic encrypted status/command/response round trip. Record first-request and warm HTTP latency separately from Mac polling delay and provider CPU/memory usage.
- Configure the Mac once and reconnect an already paired phone nearby. Verify encrypted relay configuration and FCM registration complete while BLE stays connected. No re-pair or second owner approval should occur in an in-place app update with the same Android signing identity.
- Move out of Bluetooth range with the phone locked. Generate a deliberate harmless reminder and verify it actually appears once. FCM submission/acceptance alone is insufficient. Repeat after Mac wake, phone reboot, Doze and token rotation.
- Open the dashboard remotely: cached/stale status cannot enable controls. A fresh status round trip must succeed first. Disconnect/reconnect before submission, during submission and after a deliberately delayed acknowledgement; uncertain controls must never resend through another route or after app restart. Reconciliation must reference the saved ID/body digest.
- Deliver the same reminder over BLE and FCM around handoff; it appears once. Expired warnings and incidents resolved by a newer authenticated snapshot must not reappear.
- Revoke the phone on the Mac and verify both incoming controls and outgoing status stop, including during an in-flight request. Test local persistence/remote cleanup failures using fakes before performing the owner-run real-device check.
- Confirm monitoring alone allows the Mac's ordinary sleep behavior. Unreachable does not claim a distinction between asleep, offline, powered off or disconnected. No wake feature is present.

## Settings window and optional background startup (0.3.0)

These checks require the owner; development did not enable the background item or launch the normal app.

- Open Keepresso Mobile from Finder/launcher: settings and a Dock icon appear, with no menu bar icon. Close the window: it remains running without a Dock/menu bar icon. Reopen the app: the same settings window appears, with working copy/paste.
- With native Keepresso absent, verify the companion waits and the phone becomes Unreachable. Open native Keepresso and verify saved Nearby/Internet connections resume. Quit/relaunch native Keepresso repeatedly; verify one transport instance and no duplicate reminders.
- During an explicit trigger refresh, quit native Keepresso. Verify the worker stops and no result from the old launch becomes current. Overlapping phone refreshes must not start a second worker.
- From the app's permanent Applications location, click Enable Follow Keepresso and approve in Login Items if required. Verify actual status, the one-time managed restart, unchanged pairing and reconnection. Deny/disable approval and check the UI describes that state honestly.
- Log out/in: enabled companion starts hidden and waits for native Keepresso. Force-kill only the companion intentionally: it restarts without opening settings. Choose explicit Quit: it stays stopped for that login until manually reopened; a later login starts it again.
- Reopen after explicit Quit and verify it returns to managed operation. Disable automatic startup in Login Items and confirm it remains disabled after another login. Verify upgrades/moving the registered app do not leave an obsolete background item enabled.
