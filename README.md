# Keepresso Mobile

An unofficial Android companion for [Keepresso](https://github.com/gyorgysh/keepresso), with a small Mac helper. Check your Mac's keep-awake status, inspect active triggers, get reminders and send supported controls from your phone.

**My companion code is 100% vibe-coded, built for personal use, and provided as is.** No warranty or promised support. The original Keepresso app and its artwork belong to their upstream authors.

Bluetooth is the nearby connection. Optional internet access and background push use your own relay and Firebase project; there is no shared service to sign up for. The official Keepresso app stays separate and unmodified.

## Install the preview

Requires **Android 9+**, **macOS 14+**, Apple silicon, and the original Keepresso app. This is a personal development preview; real-device acceptance checks and limits are recorded in [ACCEPTANCE.md](docs/ACCEPTANCE.md). Unknown or stale readings stay unknown.

**Android / Obtainium:** add `https://github.com/gbettineschi/keepresso-mobile` in Obtainium and enable **Include prereleases**. Each new combined release contains one signed APK. Or download `keepresso-mobile-v<version>.apk` from [releases](https://github.com/gbettineschi/keepresso-mobile/releases). The retained signing key matches the owner's existing 0.4.2 installation, so updates preserve data and pairing. Do not uninstall first or clear data on a signing mismatch.

**Mac / Homebrew:**

```sh
brew tap gbettineschi/tap
brew install --cask gbettineschi/tap/keepresso-mobile
```

Or download `KeepressoMobile.zip` from this repository's releases and put the helper in Applications as **Keepresso Mobile.app**. When first switching a manual installation to Homebrew, quit the helper and move its old app bundle to Trash before installing the cask. Keep preferences, Keychain entries and pairing data.

The Mac preview is ad-hoc signed and not notarized. macOS may require **Open Anyway** and permission to read the saved connection again after an update. Pairing has not been removed; use **Allow saved connection…** when needed. A persistent Apple signing certificate remains an optional owner setup, not something this CI release claims to provide. See [Mac signing details](docs/MAC_SIGNING.md).

To update the Mac, quit the helper and run:

```sh
brew update
brew upgrade --cask gbettineschi/tap/keepresso-mobile
```

Use one helper at `/Applications/Keepresso Mobile.app`; the official `/Applications/Keepresso.app` stays separate. Open both apps, show a pairing invitation in the helper, scan it on Android and approve the phone on the Mac. Grant permissions through the normal OS prompts. [Build and pairing instructions](docs/BUILDING.md) cover the remaining setup.

## Build from source

The current application source is on `main`:

```sh
git clone https://github.com/gbettineschi/keepresso-mobile.git
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

[Build and pairing details](docs/BUILDING.md) · [Implemented features and limits](docs/IMPLEMENTATION.md) · [Optional relay setup](docs/SELF_HOSTING.md)

## Releases

Push a reviewed `vX.Y.Z` tag from `main`. Actions tests and packages the signed Android APK and Mac preview, publishes both together, and updates the shared Mac tap automatically. Android's retained key is held in an encrypted signing environment limited to version tags and manual checks on `main`. Ordinary pull-request builds do not use it.

Permanent downloads live in GitHub Releases. Routine CI does not upload installers; failure reports expire after one day. Successful releases remove the temporary packages used between release jobs. Standard public-repository runners are used. See [release instructions](docs/releasing.md) for signing, versions and safe retries.

## Credits and license

[GPL-3.0](LICENSE). KeepressoCore and the original artwork are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This is an independent companion, not an official Keepresso release.
