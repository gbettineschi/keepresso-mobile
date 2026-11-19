# Android and Mac preview releases

Current app source is on `main`. Review and test changes, commit and push them, then push a new numeric `vX.Y.Z` tag. The release workflow packages a signed Android APK and Apple silicon Mac helper, verifies their identities and checksums, publishes both as a GitHub prerelease, and updates the shared Homebrew tap automatically. The older v0.4.3 release was Mac-only; v0.4.7 starts the combined channel.

## Android signing and updates

The retained owner Android signing certificate is SHA-256 `166dd4da449dcccaa1e4e1b881bf77455c38f6633809aeba53480034a0b2395d`. It matches the existing phone installation. APK package, version and certificate are checked before publication; a different configured key is rejected. Keep a private backup of the signing key and password.

The existing key/password are encrypted secrets in the **android-release** Actions environment, permitted only on version tags and manual verification on `main`. No signing key is committed, passed to ordinary PR builds or uploaded in artifacts. Temporary decoded key files are private and removed after use. A person able to change trusted workflows could still misuse signing access; this setup does not claim to require an additional GitHub approval for every change.

The version tag supplies both platform display versions. Android versionCode and the Mac bundle build number use `major * 1000000 + minor * 1000 + patch`. Minor/patch must be at most 999 and the Android maximum is enforced. For example, v0.4.7 maps to 4007, above the early development codes 5/7. For local trial updates, use the release packaging path/properties and retained key. Never uninstall or clear pairing to bypass a version/signature mismatch.

Add `https://github.com/gbettineschi/keepresso-mobile` to Obtainium and enable **Include prereleases**. Each combined release contains one APK. No login, token or APK filter is needed.

GitHub builds leave Firebase client values blank. Users import their own Firebase configuration on the Mac, which sends the public Android settings over the paired connection.

## Mac packaging

The release requires macOS 14.5+ and Apple silicon. Public previews through v0.6.12 are ad-hoc signed and not notarized. The prepared release pipeline signs future Mac packages with the persistent project certificate after the separately approved rollout in [MAC_SIGNING.md](MAC_SIGNING.md). It preserves bundle ID, pairing and settings. Project signing is free and does not notarize the app; the initial transition may require a final privacy approval. The project identity is provisioned and the installed two-update permission check passed for the configured features; its scope and separate Nearby finding are recorded in that guide.

`macos/scripts/package-release.sh v0.4.7` builds without installation or normal app startup. It sets the release version, includes licences, signs the final bundle and checks its safe crypto/framing self-test. This packaging/self-check stage runs without production keys. A fresh signing-only runner then signs its named ZIP artifact using the configured project certificate and uploads a public `signing.json` receipt. Missing or mismatched production signing configuration fails the release; it never falls back to ad-hoc.

## Verification and retries

Run **Release development preview** manually on `main` with `mode: verify` and the version to verify without publishing. Each platform builds and verifies its package on its runner; no Mac production key is loaded and no installers, release or tap changes are published. Android verification still uses its existing dedicated Android signing environment.

For a Mac-only unpublished signed candidate, select the reviewed branch, `mode: mac-trial`, its exact full commit in `expected_sha`, and a new numeric version. This runs keyless Mac checks followed by the protected signing-only job. It skips Android entirely and uploads only a one-day signed Mac artifact. Follow the two-build permission acceptance in [MAC_SIGNING.md](MAC_SIGNING.md) before declaring a rollout successful. Combined release assembly and checksum publication run only for a pushed version tag. Tests do not change installed apps, permissions, power settings or pairing. Passing checks does not replace the physical-device acceptance checklist.

For tap-only retry, run **Update Homebrew tap** with the existing published tag. Use a new version rather than replacing an asset. If release assembly fails before publication, rerun the failed job while its temporary packages are available.

## Free Actions use

Only standard public-repository runners are used: ubuntu-24.04 and xcode-27. Their execution is free and does not use the private-repository minutes allowance ([GitHub billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-actions)). Caches stay within the normal 10 GiB/repository limit. Routine CI never uploads installers and saves Android reports only on failure for one day. Ordinary manual verification keeps no installer artifacts. Explicit Mac trials retain only their candidate packages and public signing receipt for one day. Tagged releases transfer packages between jobs with one-day expiry, then delete their own intermediates after successful publication. Permanent downloads are release assets, not Actions artifacts. Storage has a separate plan allowance shared with Packages; the owner's account has a $0 Actions spending block. Do not select paid larger runners, extend retention or raise spending limits casually.
