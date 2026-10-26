# Keepresso Mobile

An unofficial Android companion for [Keepresso](https://github.com/gyorgysh/keepresso), with a small Mac helper. Check your Mac's keep-awake status, inspect active triggers, get reminders and send supported controls from your phone.

**My companion code is 100% vibe-coded, built for personal use, and provided as is.** No warranty or promised support. The original Keepresso app and its artwork belong to their upstream authors.

Bluetooth is the nearby connection. Optional internet access and background push use your own relay and Firebase project; there is no shared service to sign up for. The official Keepresso app stays separate and unmodified.

## Status

**Development builds only.** The app is on [`feat/native-companion`](https://github.com/gbettineschi/keepresso-mobile/tree/feat/native-companion), in [draft PR #1](https://github.com/gbettineschi/keepresso-mobile/pull/1). `main` currently holds the original plans. There is no public release, Homebrew cask or automatic updater for this companion yet.

Real-device pairing, background delivery, sleep/wake and native controls still need the [acceptance checks](https://github.com/gbettineschi/keepresso-mobile/blob/feat/native-companion/docs/ACCEPTANCE.md). Unavailable or stale readings stay unknown; a successful build is not proof that every phone/Mac combination works.

## Install a development build

Requires **macOS 14+**, the original Keepresso app, and **Android 9+**. The current Mac development download is for **Apple silicon**; source builds target the Mac they are built on.

1. Sign in to GitHub and open a successful run of [Native companion builds](https://github.com/gbettineschi/keepresso-mobile/actions). Download **Keepresso-Mac-development** and **Keepresso-Android-development**. These artifacts expire after 14 days.
2. Unzip the Mac artifact, then its `KeepressoMobile.zip`. Put the helper in Applications as **Keepresso Mobile.app** before opening it. The app is ad-hoc signed and not notarized; macOS may require **Open Anyway** in Privacy & Security.
3. Install `app-debug.apk` on your phone using Android's normal APK-install confirmation. Open the original Keepresso app and the companion on the Mac.
4. Show a pairing invitation in the Mac helper, scan it with the Android app, and approve the named phone on the Mac. Grant Bluetooth and notification access when requested. Confirm the displayed Mac name and status before trying controls.

Use one Mac helper at `/Applications/Keepresso Mobile.app`. To update, quit it and replace that same bundle. Keep its preferences and Keychain entries. Android updates must use the same package/signing key and a compatible version code to preserve pairing; stop on a signing mismatch instead of uninstalling or clearing data.

## Build from source

Clone the app branch, rather than `main`:

```sh
git clone --branch feat/native-companion https://github.com/gbettineschi/keepresso-mobile.git
cd keepresso-mobile
```

**Mac:** Swift 6.4 with matching Xcode or Command Line Tools 27.

```sh
python3 scripts/verify-upstream.py
bash macos/scripts/build-app.sh
```

Output: `macos/artifacts/KeepressoMobile.app`. Building and the packaged self-check do not install or launch the normal helper or change power settings.

**Android:** JDK 17 and Android SDK platform/build tools 35.

```sh
cd android
./gradlew :core:test :app:lintDebug :app:assembleDebug
```

Output: `android/app/build/outputs/apk/debug/app-debug.apk` relative to the repository root. Your local debug signing key may differ from the existing development builds.

[Build and pairing details](https://github.com/gbettineschi/keepresso-mobile/blob/feat/native-companion/docs/BUILDING.md) · [Implemented features and limits](https://github.com/gbettineschi/keepresso-mobile/blob/feat/native-companion/docs/IMPLEMENTATION.md) · [Optional relay setup](https://github.com/gbettineschi/keepresso-mobile/blob/feat/native-companion/docs/SELF_HOSTING.md)

## Credits and license

[GPL-3.0](LICENSE). KeepressoCore and the original artwork are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This is an independent companion, not an official Keepresso release.
