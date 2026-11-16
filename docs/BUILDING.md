# Build and try the development apps

This is an unofficial companion. Keep the official Keepresso installation; the helper does not replace it. No server, internet relay, login item or keep-awake lease is installed by building the project.

## Install a published preview

Each [GitHub preview release](https://github.com/gbettineschi/keepresso-mobile/releases) contains one signed Android APK and a Mac ZIP. Obtainium can follow this repository with **Include prereleases** enabled. On the Mac, unzip the download into Applications or install the Homebrew preview with `brew install --cask gbettineschi/tap/keepresso-mobile`. Quit the old companion before replacing it at its existing path.

## Build from source

Routine CI checks the affected platforms and leaves installable downloads to the release workflow. [Packaging and signing](releasing.md)

## macOS

Requirements for this iroh integration: Apple silicon and macOS 14.5+ to run the helper; Intel packaging is not verified. Swift 6.4 to build/test it (Xcode/Command Line Tools 27). The package uses system frameworks, pinned iroh 1.2.0 and the unmodified KeepressoCore source. Full Xcode is optional when a compatible Command Line Tools installation is available. Older compilers can reject optional-Bool switches in unchanged upstream code; CI explicitly selects the tested toolchain rather than patching that source.

From the repository root:

```sh
python3 scripts/verify-upstream.py
swift test --package-path macos
bash macos/scripts/build-app.sh
macos/.build/app-staging/KeepressoMobile.app/Contents/MacOS/KeepressoMac --self-check
```

Unpacked build output stays under hidden `.build/app-staging`, so ordinary builds do not add a launcher entry. Keep distributable ZIPs; use the canonical Applications path for the installed app.

The self-check does not start Bluetooth or run power operations. Normal launch opens the Keepresso Mobile settings window. Closing the window hides it; Finder or the launcher reopens it. There is no menu bar icon. On a foreground opening, the guided setup appears automatically when this build or its required access has not been reviewed. One **Continue** requests relevant permissions in sequence; macOS retains every allow/deny choice. Accessibility is optional for native controls that lack a public Keepresso interface. Unavailable controls remain unavailable.

Opening the installed production app registers automatic startup; approve it in macOS Login Items if requested. **Open Login Items…** opens the system controls, and blocked startup shows a warning. Move the app to its intended Applications location first. The same app starts hidden at login, waits quietly for native Keepresso, and resumes saved connections when it opens. It restarts after abnormal exits; explicit **Quit Keepresso Mobile** stops it until a manual reopen or the next login. Initial managed startup can briefly disconnect the phone while ownership transfers to macOS. No background item is registered by the build or self-check. See [macOS lifecycle details](../macos/README.md).

The development bundle is not notarized. Use a locally built copy or inspect the source and artifact before explicitly approving a downloaded development app in macOS. Future signed distribution is separate work.

## Android

Requirements: JDK 17, Android SDK platform 35/build tools, and Android 9 (API 28) or later on the phone. The repository's Gradle wrapper pins Gradle 8.11.1.

```sh
cd android
./gradlew :core:test :app:lintDebug :app:assembleDebug
```

The APK is written to `android/app/build/outputs/apk/debug/app-debug.apk`. Install it on the phone with Android's normal explicit APK-install confirmation. Ordinary CI debug builds use disposable signing. Use the signed release APK for in-place updates of a previous public preview. On a signing mismatch, keep the existing installation and pairing. For development using an already authorized USB debugging connection:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

To run the protocol tests without an Android SDK:

```sh
cd android
./gradlew -PcoreOnly :core:test
```

Keepresso Mobile needs Nearby Devices CONNECT + ADVERTISE permission on Android 12+. Android advertises and the Mac scans/connects; the phone does not request SCAN or Location. Notifications require notification permission. The background connection uses a visible connected-device service. Denying a permission must leave a clear, recoverable state rather than simulated status.

## Guided Mac setup

Open **Keepresso Mobile** from Applications. After background startup settles, setup opens automatically, including for already-paired owners. Click **Continue** once and answer the macOS questions as they appear. Authorized system permissions skip themselves; configured folder and Steam access is revalidated locally on each explicit Continue. Finish records your choices, including declined access; **Review setup…** reopens the same flow. Hidden login startup never requests permissions. Closing the app window cancels the sequence without recording completion.

When you return from System Settings, the visible summary rechecks system permission flags automatically. **Recheck** explicitly verifies local folder/Steam access too. If access is still reported blocked after opening Settings from the summary, conditional guidance offers **Restart app**. Restart affects only this companion and restores the same-build summary; native Keepresso and saved pairing are retained. The app never toggles a system permission for you.

The flow derives access from native Keepresso's saved rules, together with the companion's nearby connection, Wi-Fi name and optional remote trigger controls:

- **Bluetooth** connects the phone and supports Bluetooth-device rules.
- **Location** allows the current Wi-Fi name and Wi-Fi rules. No coordinates or network scans are collected.
- **Calendar** full access is requested only when a Calendar trigger is configured.
- **Configured download folders** are prepared locally before a phone check can read their names and modification metadata. Downloaded file contents are never read.
- **Steam libraries** are prepared only for a Steam trigger. This reads Steam library configuration and bounded download metadata; a changed library configuration requires preparation again.
- **Accessibility**, optional, enables supported native Pause/Resume controls.

Microphone/camera activity checks use device-status APIs, not recording, and request no microphone/camera capture permission. The companion requests no Input Monitoring, Full Disk Access or Mac notification permission; phone notifications are configured in Android. Permissions granted to official Keepresso do not automatically apply to this separate app. Where macOS cannot ask again after a denial, the summary links to Privacy & Security.

Unapproved folder/Steam inputs stay unknown. A remote Check never performs their first unapproved read. Local setup runs asynchronously and does not stall ordinary paired status updates. Cancelled or unsuccessful revalidation discards old approval evidence. Development build changes and newly configured folders can require setup again; this does not reset pairing.

See the pinned version and its assessment coverage in the trigger support guide. See [trigger support](TRIGGER_SUPPORT.md) for inputs and uncertainty boundaries. This is a separate bounded assessment using native algorithms, not the running app's private cache.

## Internet and phone notifications

After pairing, follow [SELF_HOSTING.md](SELF_HOSTING.md). Import the matching Firebase files on the Mac; Android learns public client options through its encrypted session without a per-project APK. For existing pairs, update both apps in place and reconnect nearby; no new QR is needed. Keep legacy services until replacement acceptance.

## First pairing

1. Open the Mac helper and complete or skip its automatically presented setup, then select **Show pairing QR code**.
2. Open Keepresso Mobile on Android and scan the invitation QR; a pasted invitation is the fallback.
3. Approve the named phone on the Mac before the five-minute invitation expires.
4. Wait for an authenticated status response. Confirm that the Mac name and displayed readings match the real Mac.
5. Use **Check** on the **Active triggers** row for the separate bounded rule assessment. Ordinary status does not continuously run this engine.

No OS Bluetooth bonding is requested. Whether both devices complete this flow without an OS pairing dialog still requires a physical-device test. Revoking the phone on the Mac must disconnect it and require new authorization.

## First tests

For the reproducible Android pairing regression suite using two disposable
Bluetooth emulators, see [ANDROID_PAIRING_TESTS.md](ANDROID_PAIRING_TESTS.md).

Start with status, trigger refresh and loss/reconnection. Test manual controls and sleep only when intentionally ready to change the Mac's power state. Follow [ACCEPTANCE.md](ACCEPTANCE.md), including its unknown, failure and background cases.

Nearby Bluetooth has limited range. Optional Internet fallback uses iroh; background push requires your own Firebase project, with no Vercel or Firestore; see [SELF_HOSTING.md](SELF_HOSTING.md). No remote-wake feature is provided. A disconnected Mac is **Unreachable**, with its last known readings retained.

Official Keepresso can update independently. The observer's pinned library does not update automatically; incompatible app/settings versions must show an unavailable assessment until the companion is updated. The pin and original-source digest list are in `shared/upstream.json`.

## Updating an installed trial

Keep one installed Mac companion at **`/Applications/Keepresso Mobile.app`**. Quit that companion gracefully, replace the verified bundle at that same path, then reopen it. Preserve its bundle identifier and credential/storage identities. Do not run an extra loose copy from Downloads or build folders. Keep unpacked staging bundles hidden and clean them up afterward; distribute compressed ZIPs. Existing Keychain entries and phone pairing are retained. Ad-hoc build changes can still require macOS permission/background approval; do not grant or enable those automatically.

On Android, retain this owner's development signing key, keep the same package, increase `versionCode`, and use `adb -s PHONE_SERIAL install -r /absolute/path/app.apk`. Verify the installed version afterward. Do not uninstall or clear data as an update procedure. Stop on a signing mismatch instead of losing pairing. An automatic online updater is not implemented.
