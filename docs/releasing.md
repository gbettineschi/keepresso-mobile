# Android and Mac preview releases

Current app source is on `main`. Review and test changes, commit and push them, then push a new numeric `vX.Y.Z` tag. The release workflow packages a signed Android APK and Apple silicon Mac helper, verifies their identities and checksums, publishes both as a GitHub prerelease, and updates the shared Homebrew tap automatically. The older v0.4.3 release was Mac-only; v0.4.7 starts the combined channel.

## Android signing and updates

The retained owner Android signing certificate is SHA-256 `166dd4da449dcccaa1e4e1b881bf77455c38f6633809aeba53480034a0b2395d`. It matches the existing phone installation. APK package, version and certificate are checked before publication; a different configured key is rejected. Keep a private backup of the signing key and password.

The existing key/password are encrypted secrets in the **android-release** Actions environment, permitted only on version tags and manual verification on `main`. No signing key is committed, passed to ordinary PR builds or uploaded in artifacts. Temporary decoded key files are private and removed after use. A person able to change trusted workflows could still misuse signing access; this setup does not claim to require an additional GitHub approval for every change.

The version tag supplies both platform display versions. Android versionCode and the Mac bundle build number use `major * 1000000 + minor * 1000 + patch`. Minor/patch must be at most 999 and the Android maximum is enforced. For example, v0.4.7 maps to 4007, above the early development codes 5/7. For local trial updates, use the release packaging path/properties and retained key. Never uninstall or clear pairing to bypass a version/signature mismatch.

Add `https://github.com/gbettineschi/keepresso-mobile` to Obtainium and enable **Include prereleases**. Each combined release contains one APK. No login, token or APK filter is needed.

## Mac packaging

The release requires macOS 14+ and Apple silicon. It is ad-hoc signed, not notarized. It preserves bundle ID, Keychain service and pairing protocol, but macOS can request saved-connection approval after an ad-hoc update. Stable Apple certificate setup is documented separately in MAC_SIGNING.md and has not been provisioned by this release.

`macos/scripts/package-release.sh v0.4.7` builds without installation or normal app startup. It sets the release version, includes licences, signs the final bundle and checks its safe crypto/framing self-test. An explicitly supplied signing certificate is preserved and verified, with no silent fallback to ad-hoc.

## Verification and retries

Run **Release development preview** manually on `main` with the version to verify without publishing. Both packages and the combined checksum manifest are checked; no GitHub release or tap change is created. Tests do not change installed apps, permissions, power settings or pairing. Passing checks does not replace the physical-device acceptance checklist.

For tap-only retry, run **Update Homebrew tap** with the existing published tag. Use a new version rather than replacing an asset. If release assembly fails before publication, rerun the failed job while its temporary packages are available.

## Free Actions use

Only standard public-repository runners are used: ubuntu-24.04 and macos-26. Their execution is free and does not use the private-repository minutes allowance ([GitHub billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-actions)). Caches stay within the normal 10 GiB/repository limit. All temporary package/report artifacts expire after one day; tagged releases delete their own intermediates after successful publication. Permanent downloads are release assets, not Actions artifacts. Storage has a separate plan allowance shared with Packages; the owner's account has a $0 Actions spending block. Do not select paid larger runners, extend retention or raise spending limits casually.
