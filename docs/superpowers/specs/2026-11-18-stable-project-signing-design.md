# Stable project signing and permission continuity

Status: proposed for owner approval. No production key, GitHub signing secret, installed app or macOS privacy grant has been changed for this investigation.

## Intent and observed causes

The owner wants Keepresso Mobile updates to preserve ordinary macOS privacy permissions, with one atomic Mobile PR ready for review after a local trial. Native Keepresso and Android are outside this change. No paid Apple membership or personal Apple identity is wanted. The preferred candidate is one project signing identity for every public release, with the private key in GitHub rather than on the owner's Mac.

Two independent causes are verified in the current source/build:

1. The installed Mac companion is ad-hoc signed. Its designated requirement is a specific cdhash; the bundle identifier alone does not preserve macOS privacy identity across changes.
2. `TriggerFolderBuildIdentity.current` includes version, build and the executable SHA256. Guided setup, folder preparation and Steam preparation all use that identity, so the app invalidates its own records on every rebuild even if an OS permission survives. Removing the version alone is insufficient.

An isolated macOS experiment used a temporary keychain and a one-day test-only self-signed code-signing certificate. Two different Mach-O executables with the same bundle ID produced the same certificate-anchored requirement and passed mutual requirement validation. Temporary files/keychain were deleted and the user's keychain search list was verified unchanged. This verifies signature identity, not real TCC grant persistence.

## Approaches

- Keep ad-hoc signing: no new credential, but build identity changes and repeated approval remain. Does not meet the goal.
- Apple Developer ID plus notarization: the conventional public distribution path, but requires publisher membership the owner does not want. Users do not need membership.
- Persistent project self-signed certificate: proposed. No Apple account, fee or per-user certificate creation; stable certificate identity can support privacy continuity. It does not notarize the app or guarantee absence of Gatekeeper warnings for downloaded updates. Actual privacy behavior must be tested.

## Signing and custody

Use one project-only code-signing certificate, with a proposed ten-year validity, normal signature validation and the existing companion identifier. Use the signer-generated certificate-anchored designated requirement; never substitute a broad identifier-only requirement. Sign nested executable code before the enclosing app where applicable.

Keep an encrypted PKCS12 identity and its password in a dedicated GitHub environment. Keep the public certificate/fingerprints available for verification. The private key must never enter the repository, app, artifacts, logs or normal PR CI. A missing or mismatched configured key fails signing rather than falling back to ad-hoc or generating a replacement identity. The current Apple-certificate/legacy-Keychain signing checks remain separate; a self-signed certificate is not claimed to fix Keychain partition identity. Current paired connections already use the approved private credential file.

Only trusted release tags and an explicitly owner-approved signed trial can access the environment. Ordinary PR events cannot use it. Import into a temporary CI keychain, preserve required entitlements, verify exact signer/identifier and strict signature, and always remove temporary key material. Do not run untrusted candidate binaries while signing secrets are available. The owner's Mac downloads a signed candidate; it does not need the production private key. No system-wide certificate trust or automatic privacy grants are installed on users' Macs.

GitHub remains the primary key store. Document encrypted independent backup and recovery: losing a Mac does not affect signing; losing the only key requires a new identity and renewed user permissions. Never silently rotate keys. Exact environment rules and initial provisioning are owner-controlled deployment steps, done after the code and workflow are reviewable.

## App consent identity

Separate reusable authorization identity from individual build identity. A strictly validated certificate-signed companion derives a stable consent identity from its actual signing identity and bundle identifier, independent of version/executable bytes. Ad-hoc/unsigned/invalid code must not gain stable consent through an identifier string; retain conservative per-build invalidation for development builds.

Use the stable identity for setup coverage and local folder/Steam preparation records. Keep exact configured resources in the scope. New folders/rules, a changed signer, invalid evidence, revocation and unavailable status must still be handled honestly; a saved marker never grants OS permission. Keep worker scratch handoff bounded/private and validate the current configuration. Migration from the current ad-hoc identity can require one final setup/approval; do not silently promote old per-build records to another signer. Keep pairing, paths and credential storage unchanged.

## Verification and delivery

Tests cover same signer across changed version/build/bytes, different signer or bundle ID, invalid/ad-hoc signature, unchanged versus changed resource scope, preserved denial, failure without a signing key, exact signer checks, and secret separation in CI. Keep all 114 upstream files unchanged. Use the existing Mac suites, signer contract checks and actual fixture signature validation. No real sleep/keep-awake actions or automatic permission grants.

Prepare one signed candidate from trusted CI for `/Applications/Keepresso Mobile.app`, preserve pairing and archive the previous bundle as a ZIP. The owner approves any newly attributed privacy permission. Then rebuild/reinstall a second different candidate with the same identity, verify the actual running copy's permission status and that setup does not restart unnecessarily. Do not claim success from matching DRs alone. Public distribution changes follow that trial; the atomic PR retains the generic LLM disclosure and stays ready for review, without automatic merge/public release in this task.

## References

- Apple TN3127: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- Apple TN2206: https://developer.apple.com/library/archive/technotes/tn2206/
- GitHub environments: https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
- yabai development signing: https://github.com/asmvik/yabai/wiki/Installing-yabai-(from-HEAD)

Investigation and writing conducted by an LLM. The project-wide free identity and GitHub custody are the owner's preferred candidate; details above remain a proposal until approved.
