# iroh/direct Firebase acceptance —31 October 2026

Source integration and real-device acceptance are separate gates. Use [the approved plan](superpowers/plans/2026-10-30-iroh-firebase.md) and [Internet protocol](internet-protocol.md). Only fake native actions are used in automated tests.

| Gate | Current record |
|---|---|
| Swift core/security tests |281 tests/50 suites passed. Includes notification cancellation/isolation and checkpoint-before-modal-dismissal restart regressions. Cancellation tests use ownership/cancellation evidence rather than a scheduler-speed assertion. |
| Kotlin core |117 tests passed, including persistent endpoint identity and corrupt-state rejection. |
| Mac optimized build and upstream source |Build passed; 107 unchanged upstream files verified at1.27.0. |
| Owner Mac Firebase setup |Dedicated sender with Cloud Messaging API Admin role created in the existing project; matching files validated and stored0600 outside Git. Google OAuth and FCM `validate_only` returnedHTTP200. App shows configured, waiting for phone registration. No delivery requested. |
| Android build/lint and baseline emulator scenarios |Build/lint passed;19 emulator cases passed across TransportStateTest, StableDashboardUiTest, InternetEnrollmentTest and DirectMessagingTest, including recovery after8 failed token uploads without foreground/restart. |
| Production iroh protocol across Swift/Android, identity-only restart and forced relay |18 cases passed:8 per mode plus a restart using retained authenticated metadata per mode. Includes20 reconnects per mode, a stalled peer, concurrent sessions, duplicate fake mutations, wrong-key rejection and invalid frames/events. Both selected paths in this environment were relay; direct-path acceptance remains pending. |
| Real-phone BLE/Internet transitions and locked/background FCM |Android0.6.0/code6000 installed in place on Samsung SM-S911B after matching the currently installed signer. Mac reports one nearby connection with retained pairing. Phone USB disconnected again before independent live-screen capture; remote-path and cloud checks remain pending. |
| Physical lid/sleep/wake |Owner-action gate; not executed by automated tests. |
| Legacy retirement |Blocked on replacement acceptance. No cloud resources removed. |

The production fixture imports the same Mac transport/session implementation as the app. Android uses its production iroh connection and credential store. Bootstrap metadata arrives through an authenticated fixture carrier, not a runner-injected endpoint address or ticket. The native executor only increments a synthetic counter; it cannot issue real power actions.

Encrypted Swift reminder delivery was checked through the Android Firebase handler with the emulator screen off, including the resulting OS notification and duplicate suppression. This does **not** establish real FCM cloud delivery, Android Doze reliability or the owner's locked phone. Route policy has automated coverage; physical BLE/Internet handover and IP/relay path migration remain owner-device gates.

Mac0.6.1/build20 is installed at the canonical Applications path; Android0.6.0/code6000 is installed with the retained owner signer, matched against the actual pre-update phone APK. The saved Mac pairing file is unchanged. Keep the legacy deployment available until the remaining physical/cloud gates pass.

Reproduce the synthetic Internet checks on the dedicated Keepresso emulator: build native `InternetFixture` and the Android debug/app-test APKs, then run `python3 scripts/tests/internet_acceptance.py --sdk "$ANDROID_HOME"`. The runner refuses physical serials and non-Keepresso AVDs before installing or clearing test state. Two runner safety tests cover invalid physical/method arguments.

The independent migration review found three notification reliability defects. Regressions now cover continued token-registration retries after a prolonged outage, resolution while an earlier send/OAuth request is suspended, and optional push-storage failure preserving live broadcasts. Automatic shortening of oversized future messages remains deferred; strict byte-limit rejection is documented. No further review round substitutes for the remaining physical/cloud acceptance gates.

## Keepresso 1.30 and physical Android Wi-Fi trial, 16 November 2026

Mac 0.6.2/build 21 was installed at the canonical path with the existing pairing file unchanged. All 283 Swift tests and 114 upstream source hashes passed. The installed worker returned a timestamp and three configured rows in 4.8 seconds. The Downloads row was unknown in the standalone check, which had no folder consent.

The existing Android 0.6.0 pairing authenticated over iroh with the phone on Wi-Fi. Tapping **Check** over Internet displayed a new assessment timestamp. A one-shot check used the production encryption and Firebase sender directly. Firebase accepted the message after the phone was locked, and Android posted the test notification. This check covered the sender and Android receiver. The normal reminder scheduler, an extended Android Doze interval, and the direct-versus-relayed iroh path remain unverified on the physical phone in this trial. Legacy cloud resources were retained.

Later that day, with Wi-Fi and Bluetooth disabled and Android reporting a validated cellular connection, the phone showed fresh Mac status over Internet and completed **Check**. Android 0.6.1/build 6001 then installed in place with the existing signer and resumed live Internet status using the saved pairing. The dashboard now gives a loss of fresh status six seconds before displaying **Unreachable**. The emulator covered recovery during the grace period, the sustained-outage state and disabled controls. All 24 targeted Android instrumentation tests and 117 Kotlin core tests passed.

Android 0.6.2/build 6002 restarts that wait on return to the foreground if status is stale. The new regression test reproduced the old label on reopen and passed with the fix. All 25 targeted instrumentation tests passed. The signed update installed in place on the same phone, which resumed live Internet status after reopening.

## Heat warnings and lid-close sound, 16 November 2026

Mac 0.6.4/build 23 was installed in place with the saved pairing intact. Its 291 tests cover serious heat after a 30-second dwell and every five minutes thereafter, immediate critical heat and one-minute repeats, and mute restoration on success, playback failure and orderly shutdown. Glass is tied to the lid-close warning. The mute override starts off.

Android 0.6.4/build 6004 passed 121 JVM and 16 targeted emulator tests. The emulator verified delivery, stale alert rejection, the urgent notification channel, a 30-minute snooze limited to serious heat, and the temperature information sheet. The signed APK matched the retained owner certificate. Physical temperature alarms, lid-close audibility and installation of this Android build remain device checks.

Mac 0.6.5/build 24 installed in place and passed 292 tests. Serious alerts now have a five-minute minimum interval across cooling, new heat incidents, and helper restarts. A new period of Serious heat still needs 30 seconds before it can alert. Critical alerts are independent of that cooldown.

## Setup and restart correction —31 October

The owner reported clipped summary/recovery text and a failed restart. Summary text now retains its vertical size. A prepared relaunch could leave its parent running because AppKit ignored termination with the setup sheet attached; a retained finished helper then blocked another attempt. Restart now saves its checkpoint, cancels/dismisses the sheet, and requests termination on the next main-queue turn. Finished helper references are discarded.

Actual owner-Mac check: clicking Restart replaced parent63888 with managed process64050 without a manual launch. The setup summary returned with its existing outcomes. Native Keepresso remained process4380, unchanged. The canonical package self-check,281 Swift tests and107-file upstream digest passed. Companion-only diagnostic logs contain no pairing keys.

macOS's Device Control and Data Access panel shows the Keepresso Mobile switch on, while the current build still receives an untrusted Accessibility result. The summary now describes access for the current copy rather than claiming the switch is off. No permission was reset or granted during this check; owner reapproval remains required for remote trigger controls. A successful restart does not itself grant that access.

Follow-up, 1 November: the owner removed and re-added only the canonical companion entry and enabled it in macOS. The running app then showed **Remote trigger controls (optional): Ready**, alongside the other three ready setup rows; setup was finished without rebuilding or reinstalling. This closes the current permission-availability gate, not a real Pause/Resume command test. The installed app uses an ad-hoc designated requirement tied to its code hash, so a future changed build can require reapproval. Apple documents this identity distinction in [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). We did not inspect or modify the TCC database, so the exact reason System Settings retained the enabled, ineffective entry is not established.

Owner requested Mac-only completion after disconnecting the phone. Firebase setup was completed on the Mac using the same verified Core import/storage APIs; the native file picker did not accept automated selection and its interactive confirmation remains a separate manual acceptance item. The Mac's sender was authenticated against Google and its FCM permission/API checked using the official [no-delivery validation flag](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages/send). This does not establish phone registration or delivery. The superseded Vercel Secret was not exportable; a dedicated replacement sender key was created rather than claiming it had been recovered. Legacy credentials and services remain available.

Retain the historical records below as evidence for their dated builds, not proof of this migration.

# Device acceptance checklist

Automated tests and successful packages do not establish physical Bluetooth delivery, macOS permissions, Android background behavior or completed sleep. Record the phone model/Android version, Mac model/macOS version, installed Keepresso version, companion commit and observed result for each test.

**Initial state:** physical-device acceptance is pending. Development verification must not issue a real sleep command, start a keep-awake hold, grant permissions or enable launch at login.

## Authorization and connection

- On an unpaired foreground opening, confirm automatic setup waits for settled managed startup or a manual fallback. Show pairing QR code must not bypass that gate. With an already-paired update, setup must open without resetting authorization. Hidden login must not present setup or request first-use permissions.
- Select Continue once: already-authorized system grants skip, relevant configured folder/Steam preparation runs locally, and macOS choices proceed serially. Deny/skip and finish, close midway, then review setup; no late completion may restore canceled proof or create an invitation.
- Start pairing locally on Mac; scan on Android; approve the correct named phone. Check that no private status appears before approval/authentication.
- Deny a phone, expire an invitation and reuse a consumed invitation. Each must fail without storing authorization.
- Try an unrelated phone/app instance without an invitation. It must not read status or control the Mac.
- Restart both apps. Saved authorization should reconnect with a new encrypted session and no replayed command.
- Revoke the phone on Mac while connected. It must disconnect immediately and fail to authenticate again until explicitly paired afresh.
- Deny Bluetooth/Nearby Devices/notification permissions individually, then grant through the normal OS UI. Confirm a usable recovery path and no misleading live state.
- Leave Bluetooth range and return. Status becomes Unreachable, controls disable, last-known readings remain distinguishable, and reconnection never executes a previously pending mutation.
- Leave the dashboard open over nearby and then over internet for several minutes, including multiple status renewals. No Awake/Unreachable flicker should occur while fresh verified updates keep arriving. Test an isolated network failure and then a genuine >15-second outage; the latter must disable controls.
- Owner closes the lid and checks whether macOS actually slept. Unreachable is correct after real sleep. On wake, verify a fresh nearby service/handshake, retained pairing and no continuation of a command issued before sleep. Test closed-lid awake operation only using the owner's existing native Keepresso setup; the companion never changes that setting or holds the Mac awake for monitoring.

## Status and trigger assessment

- Verify locked/unlocked, internal/external display on/off/dimmed, lid open/closed, battery percentage and power-source changes. Unsupported readings must say Unknown/Unavailable.
- With synthetic thermal states, confirm Nominal, Fair, Serious, Critical and Unknown on the dashboard. Confirm guard activity and a thermal brewing pause are shown only when reported by current native Keepresso.
- Start/stop native manual and automatic sessions. Check Running/Not running, remaining time/Active, trigger flags and capability availability against the official app.
- Refresh triggers during both manual and automatic sessions. Check the timestamp beside **Active triggers** and **Check**. Confirm the observer stops within its budget and does not create a power hold.
- Exercise positive and negative cases across the configured rule types, including agent, microphone and downloads. All 20 pinned types have paths; test their actual required input/permission on representative hardware rather than inferring physical accuracy from fixtures. Check asynchronous warm-up, missing permissions, earlier-day timestamps and failed refreshes. Failure must preserve the previous successful timestamp and expose uncertainty.
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

- An open-lid brew sends one unattended reminder after 60 minutes without user input. Verify activity resets the hour and there is no repeated hourly notice before more user input or a new episode.
- Verify the closed-lid Glass cue and the phone card. Updating the card while the Mac stays awake is silent and shows when brewing stops. Opening the lid or confirmed sleep resolves it.
- Verify noncritical heat follows the native guard, with a five-minute minimum interval and a 30-minute snooze. Test Critical's ringing alarm, confirmed five-minute Ignore, recovery copy and actions. Simulate pressure states rather than heating the Mac.
- Verify all three Sleep now entry points present Going to sleep, Couldn’t sleep or Couldn’t request sleep from the available native evidence. Network loss alone does not prove sleep.
- Tap notification actions after disconnect. They must not queue future Mac-control actions. Opening the app should explain reachability.
- Test Android screen off/Doze, app backgrounding, OS service termination, notification denial and closed Mac lid. Observe actual delivery and power impact; record failures explicitly.

## Outside this build

Remote wake, official app trigger-state restoration, Play Store release, notarized Mac distribution and an independent security audit are outside this build. Internet foreground protocol flows are tested with synthetic peers; physical handoff and locked-phone push are not established by those tests.
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
- Open the canonical app from Applications. Verify it appears in macOS Login Items/background items without an app-specific Enable/Refresh button, and approve there if macOS requires it. Verify actual status, the one-time managed restart, unchanged pairing and reconnection. Deny/disable approval and check the warning stays visible without unregister/reregister attempts. Open Login Items must only open that settings panel.
- Verify the single Pairing section: unreadable keys show Allow saved connection… in the first slot with the specific access/locked/error explanation; without a pairing only Show pairing QR code is enabled; with one only Remove paired device is enabled. Cancel removal and verify the real pairing remains. Any actual revoke/re-pair test must use disposable authorization, never the owner's retained phone keys.
- With a disposable test setup, start while the Keychain is locked, unlock it normally, and verify silent recovery without another QR or a new grant prompt for an already trusted build. Cancel or deny an access prompt: the app must preserve credentials and wait for explicit retry. Repeated unlock/wake/activation events must not create duplicate reads or dialogs.
- Log out/in: enabled companion starts hidden and waits for native Keepresso. Force-kill only the companion intentionally: it restarts without opening settings. Choose explicit Quit: it stays stopped for that login until manually reopened; a later login starts it again.
- Reopen after explicit Quit and verify it returns to managed operation. Disable automatic startup in Login Items and confirm it remains disabled after another login. Verify upgrades/moving the registered app do not leave an obsolete background item enabled.

## Urgent warnings (0.4.0)

- In Android Settings → Warning alerts, check alarm volume, Android alert settings and the Do Not Disturb exception. Grant special access yourself if desired, then tap Test alert. Silent ringer mode is separate from alarm volume; zero alarm volume and some DND/phone policies can still silence sound. The app does not raise volume or change global DND.
- While Only while brewing is holding the Mac awake, deliberately close its lid: expect one Glass sound and one best-effort trackpad feedback request, plus one urgent phone warning. No repeated warning while it stays closed; reopen and close again for a new event. Closed-at-startup, sleep or an unknown gap must not manufacture a lid closure. Mac haptics may not be felt without trackpad contact.
- After a real Sleep now confirmation, verify the Mac actually sleeps. The app says Going to sleep only after macOS reports the transition; disconnecting is not proof of sleep. A manually enabled global closed-lid override requires the owner's native setting change first.

### Nearby advertising diagnostics (Mac 0.4.8)

Bluetooth powered on is not evidence that the companion has started advertising. The settings row shows Starting nearby until macOS completes service publication and advertising. Available nearby requires a successful advertising callback and `isAdvertising == true`; it does not prove that Android received the advertisement. Service and advertising failures have generic UI text and non-secret error codes in the companion Bluetooth log. Subscription and authentication remain separate events. To diagnose a phone that cannot find the Mac, compare these events with the phone's discovery logs before changing pairing or transport behavior.

Mac 0.4.9 publishes the 128-bit routing service without the optional local name. The earlier service/name values totalled 32 bytes against Apple's 28-byte primary-data allowance; the routing test now enforces that allowance while preserving the expected service. Apple also provides limited scan-response space and uses an overflow area, so this byte-budget test alone is not proof of physical discovery. Verify actual Android visibility and encrypted reconnect while the owner's other sharing apps remain running.

## Nearby v2 and private credentials (0.5.0)

- Update both apps in place; preserve Android package/signer, Mac path/defaults/Application Support. Existing authorization must reconnect without another QR.
- Existing Keychain values may need one final owner-approved migration. Confirm subsequent restart/update with the valid private file needs no Keychain read, and stored device IDs/relay still work. Fixture tests cover invalid/insecure storage and failed migration; never corrupt the owner's file to test this.
- Phone advertises, Mac connects as central. Verify fresh encrypted nearby status while QuickDrop and Tetherbug continue running. Observe foreground and background, then owner-controlled sleep/wake and closed-lid behavior under unchanged native Keepresso settings. True sleep is expected to make the Mac Unreachable; disconnection alone does not prove sleep.
- With the Mac screen locked after login, confirm fresh status and intentionally chosen safe controls can journal outcomes. Background journals/outbox use [protection until first user authentication](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionuntilfirstuserauthentication), retaining0600 permissions, atomic replacement and durable sync. Automated fixture tests were run while the host was already locked; tests do not lock/unlock it.
- Existing global closed-lid overrides and unavailable safe remote sleep remain native limitations, not a transport fix.
