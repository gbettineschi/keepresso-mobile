# Build and try the development apps

This is an unofficial companion. Keep the official Keepresso installation; the helper does not replace it. No server, internet relay, login item or keep-awake lease is installed by building the project.

## Build artifacts

The public repository's **Actions → Native companion builds** workflow produces development artifacts after the corresponding checks pass:

- **Keepresso-Android-development** contains `app-debug.apk`.
- **Keepresso-Mac-development** contains `KeepressoMobile.zip`.

These are test builds, not Play Store or notarized releases. Downloading an artifact requires signing in to GitHub. Artifacts expire after one day; manually run the workflow to produce fresh ones.

Automatic builds run for pull requests and pushes to `main`. Feature-branch pushes are not built a second time. A small Linux job selects the affected platform checks: relay changes do not start a Mac build, and ordinary documentation changes start no app builds. Shared inputs and workflow changes run every affected check. Pull requests use their complete diff to keep earlier changes covered; an unrelated later commit does not erase required checks. **Run workflow** explicitly runs all checks and packages both apps. Standard GitHub-hosted Linux and Mac runner execution is free for this public repository; artifact/cache storage has separate allowances.

## macOS

Requirements: macOS 14 or later to run the helper; Swift 6.4 to build/test it (Xcode/Command Line Tools 27). The package uses system frameworks and the pinned, unmodified KeepressoCore source. Full Xcode is optional when a compatible Command Line Tools installation is available. Older compilers can reject optional-Bool switches in unchanged upstream code; CI explicitly selects the tested toolchain rather than patching that source.

From the repository root:

```sh
python3 scripts/verify-upstream.py
swift test --package-path macos
bash macos/scripts/build-app.sh
macos/artifacts/KeepressoMobile.app/Contents/MacOS/KeepressoMac --self-check
```

The self-check does not start Bluetooth or run power operations. Normal launch opens the Keepresso Mobile settings window. Closing the window hides it; Finder or the launcher reopens it. There is no menu bar icon. Nearby Bluetooth is enabled separately by the owner and may request Bluetooth access. It does not grant that access itself. Accessibility access is a separate, optional permission for native controls that lack a public Keepresso interface; unavailable controls must stay unavailable until their adapter is supported and authorized.

When the canonical installed helper opens, it registers its bundled background agent automatically and can repair a positively identified stale registration once. macOS may still require approval in **System Settings → General → Login Items**; the helper never overrides that choice. It starts hidden at login, waits for native Keepresso and resumes saved connections when it opens. Explicit **Quit Keepresso Mobile** stops it until a manual reopen or the next login. Building and the self-check register nothing. See [macOS lifecycle details](../macos/README.md).

The development bundle is not notarized. Use a locally built copy or inspect the source and artifact before explicitly approving a downloaded development app in macOS. Future signed distribution is separate work.

## Android

Requirements: JDK 17, Android SDK platform 35/build tools, and Android 9 (API 28) or later on the phone. The repository's Gradle wrapper pins Gradle 8.11.1.

```sh
cd android
./gradlew :core:test :app:lintDebug :app:assembleDebug
```

The APK is written to `android/app/build/outputs/apk/debug/app-debug.apk`. Install it on the phone with Android's normal explicit APK-install confirmation. Ordinary CI debug builds use a disposable debug identity and are not an update channel for the owner's installed app. Tagged releases use the retained owner key from the protected signing environment; use their APKs through Obtainium. Local builds that update that installation must use the same retained key. Stop on a signing mismatch; do not uninstall or clear data to force an update. For development using an already authorized USB debugging connection:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

To run the protocol tests without an Android SDK:

```sh
cd android
./gradlew -PcoreOnly :core:test
```

Keepresso needs Bluetooth/Nearby Devices access; older Android versions also use location permission for BLE discovery. Notifications require notification permission. The background connection uses a visible connected-device service. Denying a permission must leave a clear, recoverable state rather than simulated status.

## First pairing

1. Open the Mac helper and initiate phone authorization locally.
2. Open Keepresso on Android and scan the invitation QR; a pasted invitation is the fallback.
3. Approve the named phone on the Mac before the five-minute invitation expires.
4. Wait for an authenticated status response. Confirm that the Mac name and displayed readings match the real Mac.
5. Use **Refresh** under **Active triggers** for the separate bounded rule assessment. Ordinary status does not continuously run this engine.

No OS Bluetooth bonding is requested. Whether both devices complete this flow without an OS pairing dialog still requires a physical-device test. Revoking the phone on the Mac must disconnect it and require new authorization.

## First tests

For the reproducible Android pairing regression suite using two disposable
Bluetooth emulators, see [ANDROID_PAIRING_TESTS.md](ANDROID_PAIRING_TESTS.md).

Start with status, trigger refresh and loss/reconnection. Test manual controls and sleep only when intentionally ready to change the Mac's power state. Follow [ACCEPTANCE.md](ACCEPTANCE.md), including its unknown, failure and background cases.

Nearby Bluetooth has limited range. Optional encrypted internet fallback and background push require your own configured relay; see [SELF_HOSTING.md](SELF_HOSTING.md). No remote-wake feature is provided. A disconnected Mac is **Unreachable**, with its last known readings retained.

Official Keepresso can update independently. The observer's pinned library does not update automatically; incompatible app/settings versions must show an unavailable assessment until the companion is updated. The pin and original-source digest list are in `shared/upstream.json`.

## Updating an installed trial

Keep one installed Mac companion at **`/Applications/Keepresso Mobile.app`**. Quit that companion gracefully, replace the verified bundle at that same path, then reopen it. Preserve its bundle identifier and credential/storage identities. Do not run an extra loose copy from Downloads or build folders. Keep unpacked staging bundles hidden and clean them up afterward; distribute compressed ZIPs. Existing Keychain entries and phone pairing are retained. Ad-hoc build changes can still require macOS permission/background approval; do not grant or enable those automatically.

On Android, retain this owner's development signing key, keep the same package, increase `versionCode`, and use `adb -s PHONE_SERIAL install -r /absolute/path/app.apk`. Verify the installed version afterward. Do not uninstall or clear data as an update procedure. Stop on a signing mismatch instead of losing pairing. Obtainium tracks the signed APKs in GitHub preview releases; enable prereleases. See [release instructions](releasing.md).
