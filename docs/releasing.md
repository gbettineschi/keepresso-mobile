# Android and Mac preview releases

The application source remains on `feat/native-companion` (draft PR #1). Do not tag `main`, which holds plans rather than the app. Review and push the implementation source, then push a new numeric `vX.Y.Z` tag from that branch.

**Release development preview** tests/packages the Apple silicon Mac helper and a signed Android release APK. It publishes both archives, `SHA256SUMS` and `release.json` together as a GitHub prerelease. Its dependent job updates the shared Homebrew tap from the exact published Mac ZIP. No manual tap editing is needed.

Android uses the same retained owner signing key already used by CI development builds. The existing encrypted `ANDROID_SIGNING_STORE_BASE64` and `ANDROID_SIGNING_PASSWORD` secrets are reused; neither key nor password is committed or included in artifacts. Release builds fail without this identity. The APK's package, version and certificate are verified against the key before publication. Temporary key files are private and removed afterward.

The version tag supplies both platform display versions. Android's `versionCode` is `major * 1000000 + minor * 1000 + patch`; minor/patch are limited to999, and the Android maximum is enforced. For example, `v0.4.3` maps to4003. Future tags must increase the version. This scheme supersedes early development codes5/7. To update a tagged installation with a local trial build, use the same release-version properties instead of the old debug defaults; never uninstall or clear pairing to bypass a version or signature mismatch.

For Obtainium, add `https://github.com/gbettineschi/keepresso-mobile` and enable **Include prereleases**. Each combined release contains one APK. The existing `v0.4.3` release is Mac-only; Android release downloads start with the next deliberately published combined tag. The active local Android workspace has newer work than the original GitHub snapshot, so do not create a newer APK release from stale source just to test packaging. Review/push the desired app source first.

For verification without publishing, run **Release development preview** manually on `feat/native-companion` and supply the version tag to check. Both packages are built and checked, including cross-job artifact assembly, but no GitHub release or tap change is made. Verification artifacts expire after one day. No app or device is installed, launched normally or changed. The existing development workflow remains available separately.

The preview requires Android9+, macOS14+, Apple silicon and the original Keepresso app. Mac builds are ad-hoc signed, not notarized. Passing checks does not replace the real-device acceptance tests. Source and third-party licences are included in the Mac bundle, with matching source at the release tag.

The tap-only `TAP_DEPLOY_KEY` is separate from Android signing. To retry just the catalog, run **Update Homebrew tap** with the existing published tag. Do not replace an existing release asset.
