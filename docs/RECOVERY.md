# Recover or redo the setup

This guide is for iroh + direct Firebase. The [legacy recovery guide](legacy/RECOVERY.md) covers older Vercel/Firestore installations. A transport failure is not a reason to erase pairing.

## Start with what still works

| Symptom | First action |
|---|---|
| Nearby works, Internet does not | Check Internet fallback on both devices and usable Internet on both. Reconnect nearby to refresh the saved endpoint. |
| Internet works, no alerts | Check the Mac’s notification state, the Firebase project/API/account, Android notification permission and background restrictions. |
| Phone waits for registration | Open it with Internet available; it persists and retries the current token registration. |
| Replaced Firebase project asks for restart | Reopen Android as indicated; retain app data and pairing. |
| Private storage unavailable | Do not delete all state. Check the named file’s ownership, mode and integrity; other connection state is independent. |
| Mac is unreachable after sleep | Wake it yourself. Remote wake is not implemented. |

## Accessibility switch is on, but trigger controls are unavailable

macOS can retain an enabled entry while refusing access to a newly signed development build. The companion reports whether its current copy is trusted; the switch alone is not proof.

1. Open **Review setup… → Continue → Open Settings…** beside Remote trigger controls.
2. In Privacy & Security, find the companion's Accessibility entry (called **Device Control and Data Access** on the tested macOS27). If it remains unusable, remove only **Keepresso Mobile**, add `/Applications/Keepresso Mobile.app` again, and approve it locally.
3. Return to the companion and press **Recheck**. If macOS still reports the old result, use **Restart app** once, then recheck. Restart closes the setup sheet and preserves its summary; it does not grant permission itself.

Keep the official Keepresso entry separate. Reapproval does not require new phone pairing. Development signature changes can require renewed OS approval; pairing keys and other saved settings remain independent.

## Replace a sender key

1. In your project’s Google Cloud service account, create a replacement JSON key. Keep the account’s role limited to Firebase Cloud Messaging API Admin.
2. Download **google-services.json** again from the same Firebase Android registration if you lost it.
3. On the Mac, use **Phone notifications → Import Firebase configuration…**, choosing both files.
4. Verify phone registration and a real locked-phone notification.
5. Delete the superseded key from that service account only after verification. If it is compromised, revoke it immediately and accept the temporary notification outage.

You do not need the old private file to generate a replacement. This does not reset phone authorization or iroh identity. The console cannot reveal an old private key again.

## Use a new Firebase project

Follow [SELF_HOSTING.md](SELF_HOSTING.md) with a new Spark project and the same Android package. Import its matching files on the Mac, reconnect the paired phone, handle any indicated Android app restart, and verify delivery. Old-project tokens cannot receive messages from the new sender. Keep the old project until acceptance; deleting it is not a reset procedure.

## Lost Internet identity

The Mac stores its independent identity in `~/Library/Application Support/Keespresso/Internet/seed.json`. If that file is absent, starting the Internet connection creates a replacement without deleting pairing. An already-authorized phone must reconnect nearby (or through an available authenticated legacy path) to learn the replacement identity. Remote-only recovery is impossible when the phone knows only the lost address.

Malformed or insecure files fail closed; they are not silently replaced. Preserve the suspect file for diagnosis. Before a deliberate identity reset, quit Keepresso Mobile using its explicit Quit command, move only that seed file aside privately, then reopen the canonical app and reconnect nearby. Do not delete `Connection/credentials.json` or revocation records. This procedure resets the Internet address, not phone authorization. It is a recovery operation, not an automated test.

## Lost phone pairing or a new device

Normal in-place updates retain pairing. If Android Keystore/app data or the Mac’s current pairing keys are genuinely lost, cloud credentials cannot reconstruct them. Remove the obsolete authorization using the phone’s settings and the Mac’s **Remove paired device**, then scan a new QR and approve that phone locally. Never restore an old authorization file blindly after revocation.

## What is stored where

All paths are under `~/Library/Application Support/Keespresso/`; the old directory spelling is intentional compatibility.

| Path | Contents and recovery |
|---|---|
| `Connection/credentials.json` | Phone authorization and retained legacy configuration. Treat as secret; losing it may require re-pairing. |
| `revocations.json`, `mutations.json`, `reminders.json` | Revoked phones, mutation outcomes and reminder state. Preserve across updates; do not replay old commands. |
| `Internet/seed.json` | Mac Internet identity, independent of pairing. Replacement requires authenticated nearby enrollment. |
| `Internet/migration.json` | Which exact device key has authenticated over iroh. Losing it may temporarily retain legacy bootstrap; it grants no authority. |
| `Notifications/sender.json` | Private FCM sender configuration. Recover by importing a new key and matching client configuration. |
| `Notifications/tokens.json`, `Notifications/outbox.json` | Phone registration and bounded encrypted delivery state. No queued power commands. |

Private directories must be user-owned with mode 0700; private files must be regular single-link files owned by that user with mode 0600. Symlinks and malformed data are rejected. Other software running as your user can read these files. FileVault protects the disk at rest; it is not isolation from programs running in your signed-in account.

Legacy Keychain entries are not kept in sync after private-file migration and can contain obsolete/revoked authorization. Reinstalling the same app should reuse current files, not restore old Keychain state over them. Preserve the companion’s preferences/Mac UUID and complete current state when making a private Mac backup; copying a single JSON file to another Mac is not a supported migration procedure.

## Clean reconstruction

Install the canonical Mac app and Android package, restore native Keepresso independently, pair the phone, and create/import your own Spark/FCM setup. No Vercel deployment, Firestore database or original backup text file is needed. Keep payment/billing disabled. Verify status, explicit trigger checks and locked-phone alerts before relying on it.
