# Tetherbug comparison and proposed reliability change

Status: owner approved transport approach 2 and credential option B on 28 October. The owner then disconnected the phone and requested complete builds/emulator checks first; sideloading and physical tests wait until reconnection. No real credential migration has been performed.

## Observed result

Keepresso Mobile Mac 0.4.9 / Android 0.4.7 still reports No nearby Mac found after saved access was approved. Authenticated Internet snapshots are fresh. The smaller advertisement passed its primary-budget regression but did not establish physical discovery. Earlier bounded unfiltered passive scans received other advertisements but no Keepresso service/name; comparison runs included window foreground and restarting only Nearby. macOS reports isAdvertising true. QuickDrop and Tetherbug were left running; conflict with either app is unproven.

The temporary phone scan package was removed. The main phone APK/data and native Keepresso were preserved.

## What differs in Tetherbug

Tetherbug's public build script uses ad-hoc signing. Its architecture does not depend on paid signing to avoid application-key prompts.

The Android phone advertises; the Mac is a BLE central that retrieves an existing connected peripheral or scans for the service. Its BLE characteristics require an encrypted, bonded OS link. The agent keeps the hotspot password in memory; the OS manages the Bluetooth bond. This differs from Keepresso's unbonded application-encrypted link and separately persisted phone/Internet credentials. Tetherbug's local agent socket is user-only (0600).

Sources:
- https://github.com/xav-ie/Tetherbug/blob/main/macos/build.sh
- https://github.com/xav-ie/Tetherbug/blob/main/macos/Sources/Agent.swift
- https://github.com/xav-ie/Tetherbug/blob/main/macos/Sources/Socket.swift
- https://github.com/xav-ie/Tetherbug/blob/main/docs/protocol.md

## Transport approaches

1. Keep the Mac peripheral and investigate public Core Bluetooth advertising/coexistence behavior further. This preserves current implementations, but neither foreground nor a service restart restored discovery, and the payload reduction also failed in the normal client. Do not interrupt other apps' transfers to force this architecture to work.
2. Recommended: advertise from Android and connect from the Mac, as in the working Tetherbug setup. Preserve Keepresso's application authentication, encryption, freshness and durable command IDs; this does not mean replacing its security with Tetherbug's bond alone. Keep existing device IDs/keys and relay pairing. The updated apps may require one Android Nearby advertising permission, controlled by the owner. Do not assume cross-app coexistence until tested physically.

Use a separate service identifier/version for the changed GATT direction so old clients do not mistake another phone for a Mac. The phone remains the logical authentication client and the Mac remains the logical authenticated command server. Keep framing limits, notification/write queues, stale-callback generations and uncertain-command handling. Internet transport and routing priority remain unchanged.

## Credential storage choice

The four observed prompts are two access checks for each of two Keychain items. The chosen free ad-hoc builds change identity on update. BLE connectivity itself does not require these per-build Keychain reads; our persisted application credentials do.

A. Keep Keychain app-level access protection and accept update prompts. Combining records could reduce the count, but would not establish prompt-free updates.

B. Recommended for the requested free update experience: a private local credential file, directory0700/file0600, owned by the current macOS user. Keep application encryption and paired-device authorization unchanged. This protects against other local users, but another program running as the same user with filesystem access can read the secrets; it has less per-app isolation than Keychain. No claim that this is the same storage mechanism as Tetherbug.

If B is selected, migration must read the already saved keys with explicit owner OS approval, atomically write and reload/validate the private file, and preserve the existing device IDs, keys, relay config and revocations. Do not delete the existing Keychain records during migration. Subsequent launches/updates read the private file without Keychain access. Enforce owner/mode/type/size validation and no symlink following. Corrupt/insecure storage is an error, never an empty pairing slot or a reason to reset authorization. Do not weaken Keychain ACLs or make credentials public.

The owner authorized private-file migration. Perform it only through the updated app after device reconnection; development uses fixtures, never reads the real keys or changes Keychain ACLs.

## Acceptance

- Fixtures first: storage integrity, permissions, migration failure/rollback, protocol/framing, authority/freshness, transport switches and duplicate/uncertain commands.
- Emulator: pairing and the reversed GATT roles, background/foreground behavior and route handover using synthetic devices.
- Physical phone: discovery and encrypted connection while Tetherbug and QuickDrop remain running, sustained status, reconnect after owner-initiated sleep/wake, and closed-lid behavior under the owner's selected native Keepresso settings.
- No native Keepresso patch, power changes or real sleep/keep-awake commands from development tests.

## Agreed integration contract

- New GATT service: `73f8d1c0-823f-4c2f-9e0a-4454129f3101`. Android is peripheral/advertiser; Mac is central.
- Phone → Mac: characteristic `73f8d1c0-823f-4c2f-9e0a-4454129f3102`, notify with CCCD. Mac → phone: `73f8d1c0-823f-4c2f-9e0a-4454129f3103`, write with response. Neither carries private plaintext after the existing authenticated session is established.
- Android calls its existing subscribed callback once after a central enables notifications; the phone sends the existing pair/hello messages. Mac remains logical command server. Crypto/framing/message version stays v1. New service prevents a v1 scanner mistaking a phone for a Mac.
- The advertisement contains only the new service UUID. Discovery metadata is never authorization. OS bonding is not required; preserve the existing app-layer mutual authentication and encryption.
- Keep the native `BluetoothServer` façade API used by `CompanionModel`; its physical implementation becomes central. Android `BlePeripheral` provides `start(resetCandidates:Boolean=false)`, `close(reason:String?)`, `send(text:String)`, and `authenticated()`, with the existing state/subscribed/record/disconnected callback meanings.
- Private store: `~/Library/Application Support/Keespresso/Connection/credentials.json`; private directory0700 and file0600, current owner, regular file, bounded64KiB. Existing legacy namespace is deliberate. Symlinks/insecure files fail closed. The existing CredentialStore façade API stays intact. A valid file is authoritative and bypasses Keychain entirely. If absent, the legacy reader runs under the existing explicit/silent policy, and a validated atomic file write must succeed before authorization becomes ready. Preserve old Keychain items for recovery; never widen ACLs.
- Trial versions: Mac0.5.0 build13; Android0.5.0 code5000 (above installed4007), original owner package/signing key. No release publishing or owner installation until the phone reconnects.
