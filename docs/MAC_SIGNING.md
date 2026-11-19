# Mac signing and permissions across updates

Keepresso Mobile can use one persistent, self-signed **project certificate** for Mac releases. Users install the app; they do not create or import a signing certificate. No paid Apple account is required for this signing method.

**Rollout verified on 19 November 2026:** the three-year project identity is provisioned in the protected GitHub environment. Signed trial0.6.13 received the owner's initial setup approvals; signed trial0.6.14 was then installed at the same path. Its automatic setup did not restart. An explicit review revalidated configured folders and showed Bluetooth, Wi-Fi name, folders and remote controls Ready without new OS permission dialogs. The setup record, pairing credentials and native Keepresso binary were preserved. Existing pairing also connected over Internet. Public downloads through v0.6.12 remain ad-hoc; no new public release has been published yet.

This trial exercised the owner's configured features, not calendar/Steam or an intentionally revoked real grant. Automated tests cover denied-state preservation. A separate Nearby handshake/write failure was observed and is under investigation; permission readiness does not establish successful Bluetooth authentication.

## What this fixes

Ad-hoc signing identifies a particular build. Changing the executable can make macOS stop recognizing an old privacy authorization. Separately, the companion previously bound its setup and local trigger-preparation records to the executable's version and bytes, reopening setup on every build.

A validated certificate-signed build now uses the exact companion identifier and signing certificate for those records. The same certificate can keep that identity across updates. A different certificate, invalid signature or changed folder/Steam configuration does not inherit the old preparation. The saved record never grants an OS permission: current framework permission checks still apply.

The first move from an ad-hoc build may require one final approval. Test two consecutive project-signed builds before promising persistence. Revoked permissions remain revoked.

## What this does not fix

Self-signing is **not Developer ID signing or notarization**. macOS may still block a downloaded app until the user explicitly opens it. Do not install global certificate trust, weaken Gatekeeper or reset privacy permissions automatically.

Historical pairing builds used Keychain items with a separate per-app partition check. A self-signed certificate is not a fix for that check. Current connections use the approved private credential file; an update with a valid file does not reload old Keychain items. Signing never resets phone pairing.

## Public project certificate

The [public certificate](signing/keepresso-mobile-project.pem) identifies this project's Mac signer. It contains no private key and is supplied for verification, not to install global certificate trust.

- Valid from 19 November 2026 through 19 November 2029, 12:59:23 UTC (three calendar years).
- Certificate SHA-1: `8945c703d1ab6a3d21e80feab6c8a0292449ed52`.
- Certificate SHA-256: `9c1cf1889b0b5a67f2e4ab642c82cbae16f6fea78be40f18d3e2aa6782ff24bf`.

## Where the private key lives

Use a dedicated **macos-release** GitHub Actions environment with these secrets:

| Secret | Value |
|---|---|
| `MACOS_SIGNING_PKCS12_BASE64` | Base64 of the password-encrypted project PKCS12 identity |
| `MACOS_SIGNING_PKCS12_PASSWORD` | Its password: minimum 8 characters; generate 32+ random characters |
| `MACOS_SIGNING_CERTIFICATE_SHA1` | Exact 40-hex signing certificate fingerprint; this fingerprint is public |

Environment secrets remain private in a public repository. **Before uploading any key, require GitHub-enforced approval exclusively from the repository owner and disable administrator bypass.** Allow only `v*` version tags and, temporarily, the exact approved trial branch. Remove that branch rule after acceptance. Self-approval can remain enabled for this owner-operated repository: the owner or an explicitly authorized agent acting through the owner account must verify the exact source commit before approving its signing job. The typed SHA binds a dispatch to a commit; it is not evidence of owner review. If these protection rules cannot be configured, stop provisioning; there is no unprotected fallback. The signing job verifies the environment metadata before its private-key step. [GitHub documents these controls](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

The private key must never be committed, bundled with the app, printed, attached to a PR, stored in Actions artifacts or passed to ordinary build jobs. Generate it only after explicit maintainer approval. The current identity is a project-only RSA-3072/SHA-256 code-signing certificate with three-year validity. It was generated in a private temporary directory, exported as encrypted PKCS12 and uploaded through standard input to the three environment secrets. Record the public certificate/fingerprints. Remove temporary files after successful upload; do not retain the private identity in the Mac's login keychain.

GitHub is the primary key store, not a recoverable download archive: secret values cannot be read back from its UI. Keep an independent encrypted backup if the maintainer chooses a destination. **No independent private-key backup has yet been created or selected.** The public certificate is not a signing-key backup. Losing a Mac does not affect signing while GitHub retains the key. Losing the only key requires a deliberate signer replacement and users may need to approve permissions again. Never generate a replacement silently.

## The release boundary

1. A **keyless build job** checks out the exact commit, runs tests, packages the app ad-hoc and runs its safe self-check.
2. A **fresh signing runner** waits for the mandatory owner approval in `macos-release`. It downloads only the named candidate from that same workflow run and verifies the checkout SHA.
3. The signer imports the configured identity into a temporary keychain accessible to `codesign`. It validates a bounded single-app archive, rejects nested executables and key material, signs without running candidate code, and verifies the exact certificate and default designated requirement.
4. Only the signed ZIP and public signing receipt are uploaded. Temporary key files and keychain are removed even after errors; artifacts expire after one day.

A missing key, wrong fingerprint or invalid app fails the job. There is no ad-hoc fallback in project mode. Never call `build-app.sh`, `package-release.sh`, an app self-check or the candidate executable in the production signing job.

Ordinary PR CI stays keyless. Local development remains ad-hoc unless an identity is explicitly supplied. The older `apple` signing profile retains its stricter Apple-chain/legacy-Keychain checks; the new `project` profile stabilizes privacy identity without claiming those Apple-chain guarantees.

## Unpublished Mac trial

In **Release development preview**, choose the approved branch, `mode: mac-trial`, a new numeric version such as `v0.6.13`, and its full reviewed commit in `expected_sha`. A moved branch fails the check. The workflow path already exists on `main`, so the trial can run before merging its implementation branch.

Use `scripts/verify-macos-signing-environment.py` with the repository, environment and deployment-ref JSON returned by the GitHub API to verify these protection settings before key upload; the workflow repeats that check before signing.

The trial creates only a signed Mac artifact, retained for one day. It does not run Android signing, publish a GitHub release or update Homebrew. Download `Keepresso-Mac-release`, verify the ZIP against `signing.json`, then verify the certificate and strict signature. Replace only `/Applications/Keepresso Mobile.app`; keep pairing, settings and Application Support.

For acceptance:

- Install candidate A and handle any initial privacy approvals locally. Check the actual usable permissions, including existing allowed and deliberately denied features, not just enabled switches in Settings.
- Build candidate B with a different version/bytes and the **same certificate**, then update the same installed path.
- Confirm the two designated requirements and read-only authorization identities match; setup does not restart unnecessarily; granted features still work and declined features remain declined; saved pairing still reconnects.
- If macOS still rejects permission or demands extra certificate trust, stop and report it. Do not clear TCC, auto-grant permissions or add trust to make the trial pass.

## In-place update and the managed process

Keep one installed app at `/Applications/Keepresso Mobile.app`. Before replacing it, stop both its foreground app and its exact per-user managed job, `local.keepresso.mobile.follow`. That job's process name is just `KeepressoMac`; matching only an absolute command path can miss it. An old registered job can otherwise restart the previous executable while the bundle is moving.

The new canonical app automatically rebinds an already-authorized stale registration. Do not override revoked Login Items consent, erase pairing, reset TCC or launch an old copy from Trash to repair the transition. This procedure changes startup registration, not the user's permission decisions.

## Developer checks

```sh
python3 macos/scripts/test-sign-app.py
python3 macos/scripts/test-sign-candidate.py
python3 macos/scripts/test-ci-project-signing.py
python3 -m unittest discover -s scripts/tests -v
```

The tests above use injected tools and do not access real signing keys. An additional **opt-in** integration fixture uses one-day temporary test certificates/keychains, verifies actual signing and running-code identity across changed builds, rejects wrong signers/tampering, and checks cleanup. It never grants TCC or changes trust:

```sh
KEEPRESSO_APP_DESTINATION="$PWD/macos/.build/privacy-fixture/KeepressoMobile.app" bash macos/scripts/build-app.sh
python3 macos/scripts/test-project-signing-integration.py \
  --allow-temporary-keychain-probe \
  --app macos/.build/privacy-fixture/KeepressoMobile.app
```

These signature checks do not replace the real permission acceptance above. See [Apple's designated-requirement explanation](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) and [code-signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/).
