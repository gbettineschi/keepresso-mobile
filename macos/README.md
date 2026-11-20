# Keepresso Mobile helper

Unofficial background companion for the unmodified Keepresso app. macOS 14+ to run, Swift 6.4 (Xcode/Command Line Tools 27) to build/test the unchanged upstream source. It has no menu bar icon. Open **Keepresso Mobile** from Finder or the launcher for settings; closing the window hides it and removes its Dock icon while it keeps running.

Opening the installed production app registers automatic startup; **Open Login Items…** opens macOS controls, and a warning appears if approval is required. macOS may require approval under **System Settings → General → Login Items**. It starts this same app hidden at login and restarts it after a crash or forced kill; there is no separate watcher. Native Keepresso launch/quit events resume/suspend the saved connections and reminders. While native Keepresso is absent, the companion waits without polling or running the trigger engine. An initial switch to managed startup restarts the companion once and may briefly disconnect the phone; pairing is retained.

To stop it, reopen settings and choose **Quit Keepresso Mobile** (or Command-Q). An explicit Quit is respected until a manual reopen or the next login. Disable automatic startup in macOS Login Items if you also want it to stay off at future logins. Moving or replacing a registered app may require re-enabling it from its installed location.

## Build and verify

From repository root:

```sh
swift test --package-path macos
bash macos/scripts/build-app.sh
macos/.build/app-staging/KeepressoMobile.app/Contents/MacOS/KeepressoMac --self-check
```

The script uses Command Line Tools, builds a release executable, bundles original artwork/localizations, and signs `macos/.build/app-staging/KeepressoMobile.app`. With no configured identity it makes an ad-hoc development build. Existing Keychain values may require one-time migration approval; later valid-file loads bypass Keychain. Owner builds can require an exact Apple-issued signing certificate with `KEEPRESSO_CODESIGN_IDENTITY` and `KEEPRESSO_REQUIRE_STABLE_SIGNING=1`; see [stable Mac signing](../docs/MAC_SIGNING.md). It does not install or launch the normal helper. Self-check branches before AppKit initialization, credentials, Bluetooth, the observer, status readers or power adapters. No real power commands run in tests.

Swift 6.4 Command Line Tools currently require an explicit Swift Testing macro plugin path; Package.swift applies this only when that compiler/plugin is present. The default Swift build/test tool interface remains supported. Local CLT linker warnings about absent Developer framework search directories are environmental; production source compiles without concurrency warnings.

## Implementation boundaries

- CryptoKit implements the exact shared protocol and independently generated Node vectors. The Mac central connects to the phone-advertised v2 service; each peer has bounded framing and acknowledged write queues. Private traffic starts only after mutual authentication. Pairing needs a local five-minute QR invitation and a local approval; credentials are in the owner-only private file described in [Recovery](../docs/RECOVERY.md), and revocation drops sessions immediately.
- A durable, synchronized mutation reservation precedes every side effect. The journal binds device, ID and body; crashes stay uncertain. The executor serializes all native mutations, including across phones, and never queues a rejected mutation or replays an uncertain operation. Journal corruption/full capacity disables controls.
- Start/Stop target the installed `/Applications/Keepresso.app` public URL interface. A fresh native status-file write and the requested resulting state are required for an acknowledgement. File modification time handles the native timestamp's whole-second precision. Acknowledgement stays bound to the originating PID and launch date. A native restart or authorization change before journal completion leaves the issued operation uncertain, without retrying.
- Pause/Resume require Accessibility permission, pinned version 1.27.0, and exactly one enabled, exposed native AX button/menu item with the exact expected English title and a Press action. No guessed menu opening or coordinate click is used. Localization or an absent/ambiguous control makes the action unavailable. Capability probing is bounded; it does not establish screen visibility.
- **Sleep now requires verified native evidence.** The companion checks current phone authorization and native wake/session evidence, requests Stop, verifies that Keepresso released its session and sleep override, then makes one normal macOS sleep request. A separate global sleep override must be released on the Mac. The phone offers confirmation even while status is updating or unavailable; it never queues sleep for a later reconnect. Disconnection is not proof of sleep.
- Native status uses the current app process and `status.json`. A running app with unreadable/invalid status stays unknown; an observed absent app is known to have no brewing session. Global system sleep overrides may outlive that process and are not inferred inactive.
- Mac readings include lock when available, display on/off, lid, battery and power source, and Apple’s macOS thermal state. Keepresso Mobile sends noncritical thermal warnings when native Keepresso reports that its configured guard is acting. The notification-capable native build publishes its wake and brewing state. A confirmed full wake allows the unattended, closed-lid and heat alerts. The dashboard can still display Apple’s thermal state with older native builds.
- The unattended alert fires once after an hour without input during open-lid brewing. The closed-lid notification stays current while the Mac is confirmed awake. The critical incident can recover without losing its history. Nearby delivery requires an authorized connection; background delivery uses the paired phone’s Firebase registration.

## Trigger observer

Only explicit **Check** launches a separate instance of this executable with the internal `--observe-triggers --observer-scratch <private-temp-path>` flags. Concurrent refresh requests are rejected. Native Keepresso quitting cancels the active check and invalidates its result. The parent owns the scratch directory, caps output at 64 KiB, and enforces a twelve-second parent bound around the eight-second engine watchdog, then kills the worker process group, reaps it and removes scratch before returning. This is process isolation, not a real-time OS scheduling guarantee. Ordinary status/reminders never construct the duplicate engine or a power assertion.

The worker strictly decodes every saved rule before using KeepressoCore, preventing its intentionally lossy unknown-rule fallback. Hook readers receive disposable copies only; the adapter retains upstream's exact older shared-host Codex rollout-freshness exception. The original Sources files remain byte-identical; companion adapters also locate the unchanged localization resources in the standard signed app bundle.

All 20 pinned Keepresso 1.30.0 rule types have explicit audited input paths through the unchanged factory. Verified complete inputs can establish inactive results. Partial readings may still establish activity when there is direct positive evidence. See [trigger support](../docs/TRIGGER_SUPPORT.md). A completed partial assessment gets a new timestamp. A timeout or settings error preserves the previous timestamp. The preview tracks its own grace periods independently of the running native engine. Physical microphone, download, and agent transitions and signed-helper permissions remain acceptance work.

## Guided setup

On foreground opening, an unhandled build or permission scope automatically shows setup after managed startup settles. One **Continue** handles relevant system requests in sequence; **Review setup…** reopens it. Hidden login never asks for first-use access. Native rule permission needs and companion Bluetooth/Wi-Fi/optional Accessibility needs are combined. Configured download and Steam reads are prepared locally before remote checks, and revalidated on an explicit Continue. Permission choices belong to the owner; pairing is retained. See [setup and recovery](../docs/BUILDING.md#guided-mac-setup).

## Optional Internet and phone notifications

Internet uses iroh 1.2.0 with the existing authenticated application protocol. Bluetooth is preferred. A stable independent private endpoint identity survives restarts; the paired phone learns its public identity over an encrypted existing connection. Normal enrolled operation needs no Vercel/Firestore service. First integration support is Apple silicon/macOS 14.5+.

The Mac imports its own Firebase sender JSON plus matching Android client configuration. The private sender key stays in validated local storage. Public client options go to the paired phone, which registers a revision-bound token over an authenticated session. Direct FCM and foreground events share event IDs and Android’s durable duplicate claims. No push executes a native command or proves current reachability.

The durable mutation journal remains shared across routes; uncertain delivery is not automatically retried. Native stop/sleep/wake invalidate old generations. Internet monitoring takes no awake hold. Bounded local notification retries retain the original expiry. Legacy polling is bootstrap only until that exact paired key authenticates over iroh.

See [setup](../docs/SELF_HOSTING.md), [recovery](../docs/RECOVERY.md), [wire details](../docs/internet-protocol.md) and [acceptance](../docs/ACCEPTANCE.md). The app’s Firebase acceptance message does not prove display on Android.

## Evidence and pending acceptance

`evidence/red-*.log` records actual expected test failures before implementations/fixes. `evidence/green-platform.log` contains the final full suite; `evidence/build-app.log` records the packaged build/self-check. Tests use fake native mutation adapters and temporary fixtures, never real Keepresso controls. Bluetooth hardware, QR pairing on Android, revocation, background notification delivery, closed-lid behavior, native controls, and permission behavior require owner-run acceptance. The local package is ad-hoc signed, not notarized.

Window close/reopen, Service Management approval, login startup, launchd handoff/crash recovery, KVO delivery for the native menu bar app, and actual Bluetooth reconnection still need owner-run OS acceptance. Development checks do not register the background item or launch the normal app.
