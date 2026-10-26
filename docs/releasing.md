# Mac preview releases

The application source remains on `feat/native-companion` (draft PR #1). Do not tag `main`, which still holds plans rather than the app. Use a clean checkout of the implementation branch, review the source, commit and push, then tag that commit `vX.Y.Z` and push the tag to this repository.

**Release Mac development preview** runs the Mac tests, verifies the unchanged pinned upstream files, builds the Apple silicon helper with Swift 6.4, runs its safe packaged self-check and publishes `KeepressoMobile.zip` plus `SHA256SUMS` as a GitHub prerelease. No power commands, app installation, device changes or Android release are part of this job.

The dependent tap job updates `keepresso-mobile` in [gbettineschi/homebrew-tap](https://github.com/gbettineschi/homebrew-tap) from the exact uploaded ZIP. Its `TAP_DEPLOY_KEY` can write only to that tap; no personal token or Apple signing secrets are needed. If catalog publication fails, run **Update Homebrew tap** with the existing tag or re-run the failed job. Never replace an already published ZIP to retry the catalog.

The preview requires macOS 14+, Apple silicon and the original Keepresso app. Builds are ad-hoc signed, not notarized. Passing tests does not replace the real-device checks in `docs/ACCEPTANCE.md`. Android continues using the existing development artifacts and retained signing identity.

To check packaging locally without installing or publishing:

```sh
bash macos/scripts/package-release.sh v0.4.3
```

The tag supplies the packaged app version. Source and third-party licences are included in the bundle; matching source is available at the release tag. Future releases use a new numeric `vX.Y.Z` tag.
