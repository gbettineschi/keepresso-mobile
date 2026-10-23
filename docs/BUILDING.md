# Build and try the development apps

This is an unofficial companion. Keep the official Keepresso installation; the helper does not replace it. No server, internet relay, login item or keep-awake lease is installed by building the project.

## Build artifacts

The private repository's **Actions → Native companion builds** workflow produces two development artifacts after the corresponding checks pass:

- **Keespresso-Android-development** contains `app-debug.apk`.
- **Keespresso-Mac-development** contains `KeespressoMac.zip`.

These are test builds, not Play Store or notarized releases. Downloading an artifact requires access to the private repository. Artifacts expire after 14 days; rebuild the branch to produce fresh ones.

## macOS

Requirements: macOS 14 or later and a recent Swift toolchain. The package uses system frameworks and the pinned, unmodified KeepressoCore source. Full Xcode is optional when a compatible Command Line Tools installation is available.

From the repository root:

```sh
python3 scripts/verify-upstream.py
swift test --package-path macos
bash macos/scripts/build-app.sh
macos/artifacts/KeespressoMac.app/Contents/MacOS/KeespressoMac --self-check
```

The self-check does not start Bluetooth or run power operations. Normal launch opens the menu-bar helper and may request Bluetooth access. It does not grant that access itself. Accessibility access is a separate, optional permission for native controls that lack a public Keepresso interface; unavailable controls must stay unavailable until their adapter is supported and authorized.

The development bundle is not notarized. Use a locally built copy or inspect the source and artifact before explicitly approving a downloaded development app in macOS. Future signed distribution is separate work.

## Android

Requirements: JDK 17, Android SDK platform 35/build tools, and Android 9 (API 28) or later on the phone. The repository's Gradle wrapper pins Gradle 8.11.1.

```sh
cd android
./gradlew :core:test :app:lintDebug :app:assembleDebug
```

The APK is written to `android/app/build/outputs/apk/debug/app-debug.apk`. Install it on the phone with Android's normal explicit APK-install confirmation. For development using an already authorized USB debugging connection:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

To run the protocol tests without an Android SDK:

```sh
cd android
./gradlew -PcoreOnly :core:test
```

Keespresso needs Bluetooth/Nearby Devices access; older Android versions also use location permission for BLE discovery. Notifications require notification permission. The background connection uses a visible connected-device service. Denying a permission must leave a clear, recoverable state rather than simulated status.

## First pairing

1. Open the Mac helper and initiate phone authorization locally.
2. Open Keespresso on Android and scan the invitation QR; a pasted invitation is the fallback.
3. Approve the named phone on the Mac before the five-minute invitation expires.
4. Wait for an authenticated status response. Confirm that the Mac name and displayed readings match the real Mac.
5. Use **Refresh** under **Active triggers** for the separate bounded rule assessment. Ordinary status does not continuously run this engine.

No OS Bluetooth bonding is requested. Whether both devices complete this flow without an OS pairing dialog still requires a physical-device test. Revoking the phone on the Mac must disconnect it and require new authorization.

## First tests

Start with status, trigger refresh and loss/reconnection. Test manual controls and sleep only when intentionally ready to change the Mac's power state. Follow [ACCEPTANCE.md](ACCEPTANCE.md), including its unknown, failure and background cases.

Nearby Bluetooth has limited range. This version does not deliver reminders over the internet when the phone is away. No remote-wake feature is provided. A disconnected Mac is **Unreachable**, with its last known readings retained.

Official Keepresso can update independently. The observer's pinned library does not update automatically; incompatible app/settings versions must show an unavailable assessment until the companion is updated. The pin and original-source digest list are in `shared/upstream.json`.
