# Mac signing and repeated Keychain prompts

## Confirmed incident

After the owner installed Mac 0.4.4 (8), saved-pairing unlock produced four password prompts. Read-only OS logs show exactly four prompt/approval pairs in the same managed process: decrypt authorization (`24`) and partition authorization (`65538`) for each of the two existing credential entries. The installed signature is ad-hoc, its designated requirement is a build hash, and its TeamIdentifier is absent. Old ACLs referenced earlier build hashes. No duplicate loader, incorrect password attempt, missing pairing or credential reset is inferred from these logs.

There are two identity checks. A consistent designated requirement lets the ordinary ACL recognize an update. The Keychain partition must also recognize its signer. [Apple's securityd source](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp) assigns supported Apple-issued developer/distribution certificates a `teamid:` partition and other signed code a `cdhash:` partition. A self-signed certificate alone is therefore not a complete fix. The SDK constants are in `Security.framework/Headers/cssmapple.h`; [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) explains designated requirements and ad-hoc identity changes.

On26October, a metadata-only inspection confirmed both existing items still present and the login Keychain unlocked. Their partition entries did not include the current installed ad-hoc build: devices retained an earlier build hash and relay allowed apple:. Consequently a same-build process restart can ask again if the earlier approvals were not retained. This is not loss of pairing and is not evidence that a new QR setup is needed. No credential values were read by that inspection and no ACLs were changed.

## Prepared owner-build path

The packaging script accepts an explicitly chosen Apple Development, Mac Distribution or Developer ID Application certificate. Use its exact 40-hex SHA-1 fingerprint from the owner's installed signing identity. The fingerprint identifies a certificate; it is not a secret or the private key.

```sh
KEEPRESSO_CODESIGN_IDENTITY=YOUR_40_HEX_CERTIFICATE_FINGERPRINT \
KEEPRESSO_REQUIRE_STABLE_SIGNING=1 \
KEEPRESSO_APP_DESTINATION=/absolute/hidden-staging/Keepresso\ Mobile.app \
bash macos/scripts/build-app.sh
```

Stable mode fails when no identity is supplied. An explicit identity never falls back to ad-hoc if unavailable or signing fails. The signer checks the exact certificate and bundle identifier, an Apple certificate chain matching securityd's stable-team classification, signature validity, and a certificate-based designated requirement. A development build without an identity remains ad-hoc and prints a warning; CI artifacts are development fixtures and should not be treated as the owner signing path.

This preparation does not provision a certificate. At investigation time there are zero valid code-signing identities in the owner's file-based Keychains. The owner does not want paid membership. [Xcode's signing workflow](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html) supports a free Personal Team; [Apple DTS demonstrated a local Mac app using a non-paying Personal Team](https://developer.apple.com/forums/thread/787500?answerId=861714022). The practical next step is Xcode → Settings → Apple Accounts → the owner's Personal Team → Manage Certificates → Apple Development. The owner handles Apple sign-in and two-factor authentication. Certificate issuance, compatible chain and actual cross-update Keychain behavior must be verified before declaring the fix enabled.

Xcode27.1 is installed as of26October following the owner's authorization of the free setup. No signing identity was present at the last check; Apple Account sign-in and Personal Team certificate creation remain owner-controlled steps. For reproducible repo checks, an explicit `DEVELOPER_DIR=/Library/Developer/CommandLineTools` keeps using the previous toolchain without changing the system's selection. Account/certificate setup does not require downloading mobile simulators or enrolling in a paid plan.

The installed companion has no entitlement payload or embedded provisioning profile. [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) says a Mac app without restricted entitlements needs no provisioning profile. Thus the Personal Team's seven-day **profile** lifetime should not impose a weekly profile renewal on this app as currently built; this is an inference to verify during signing setup, not a claim that a certificate never expires.

Once a suitable identity is available, keep the same signing team and compatible designated requirement for future builds. The first switch from the existing ad-hoc build may require a final owner Keychain approval. Stable signing does not bypass a locked Keychain, revoked consent or OS policy. Verify the actual next-update behavior before claiming the prompts are eliminated. Keep the signing private key under owner control, and export it only to an owner-approved secure backup if needed. Changing/loss of signing identity is separate from loss of phone pairing; never delete pairing to work around signature approval.

## Verification boundary

`python3 macos/scripts/test-sign-app.py` uses a fake signer and temporary app fixture, without real Keychain access. It verifies required-certificate gating, exact signer/identifier verification, unsupported-team rejection, no silent fallback, failure propagation and rejection of build-hash-based requirements. A normal real ad-hoc package/self-check can verify that development packaging still works; it cannot prove a persistent Apple certificate is present or that the owner has granted access across an update. No installed app is replaced merely to reproduce the four prompts.
