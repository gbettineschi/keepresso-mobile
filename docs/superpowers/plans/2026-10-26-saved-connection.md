# Saved connection recovery

Owner request: investigate repeated saved-pairing approval, fix normal reconnection, and rename the destructive pairing action to Remove paired device. Continue persistent free Personal Team signing setup.

Evidence: the installed ad-hoc build has cdhash04493468…, while its existing devices Keychain partition trusts a different cdhash and relay partition trusts apple:. The login Keychain is unlocked; both credential items exist. Metadata inspection requested no credential data. This is saved-access approval, not loss of pairing. The existing loader maps every failure to unavailable and its UI incorrectly calls every failure an unlock.

## Contract and steps

1. Keep existing Keychain service/items, bundle ID, revocations, device keys, relay configuration and Android pairing. Never repair access by deleting or replacing credentials or widening ACLs.
2. Add typed, non-secret Keychain failure classification and distinguish locked, permission required, cancelled, denied, invalid data and unavailable. Unknown credentials never mean an empty pairing slot.
3. Add coalesced silent retry on Keychain unlock and other relevant environment events; no polling, automatic permission prompts or retry loops. Cancellation/denial/invalid data require explicit retry. All IPC stays off the main actor.
4. Use Allow saved connection… for access approval, Remove paired device for actual revocation, and clear explanatory status. Preserve the QR/removal gating.
5. Test failures, recovery, event storms, cancellation and shutdown using fake readers. Run full Swift and packaging/sign-policy checks and one fresh read-only review.
6. Complete owner-controlled Apple sign-in/certificate creation, sign the canonical update with that identity, preserve installation/pairing, then verify reconnect and a subsequent update. Never claim persistent approval fixed from build tests alone.

Implementation: existing Swift app/core, a typed failure value, generic loader recovery gate, and a thin documented macOS Keychain event adapter registered on the main run loop. Keep the official Keepresso source and power settings unchanged.

Current signing setup: Xcode27.1 installed, no valid signing identity. Xcode window inspection failed with ScreenCaptureKit error; owner Apple Accounts/Personal Team certificate handoff requested. Use explicit DEVELOPER_DIR for consistent repo checks; do not change the global tool selection.
