# Stable signing implementation plan

**Spec:** docs/superpowers/specs/2026-10-24-stable-signing.md
**Goal:** Prepare a secure persistent-signing path without disturbing the now-unlocked owner installation.
**Architecture:** A small packaging-only signer accepts an exact certificate fingerprint and can require stable identity. Verify the actual signer and bundle identifier, reject hash-bound designated requirements; never silently fall back after failure.
**Constraints:** No real Keychain/permission mutations, identity creation/import, credential migration, owner reinstall or native Keepresso changes. Existing feature checkout; execute inline.

### Task 1: Packaging and guidance
- [x] Write and run failing isolated signer tests: stable mode rejects missing identity, explicit signer reaches signing/verification, malformed identity rejected, signing failure propagates, hash-bound result rejected, ad-hoc development mode warns.
- [x] Add macos/scripts/sign-app.sh and invoke it from build-app.sh; no default CI signing change. Run the signer tests and a real ad-hoc packaging/self-check into hidden staging, then remove it. Fixture-code tests do not claim a real persistent certificate was provisioned.
- [x] Document exact root cause, stable identity setup/backup boundary, expected one-time transition and secure owner build command; record installed phone/Mac read-only verification separately. One final review of packaging behavior completed; metadata-vs-DR parsing fixed with two failing regressions, total nine tests green.
- [ ] Owner approval for free Xcode installation / Apple ID certificate setup, then actual signing and first/subsequent update Keychain acceptance. No paid membership.
