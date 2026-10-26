# Android pairing regression tests

The two-device emulator harness exercises the Android app through real virtual
Bluetooth GATT, framing, authorization proofs and authenticated encryption. The
second emulator is a synthetic Mac protocol peer, not a connection to macOS.
Its manual-session, trigger and reminder operations change test data only.

Use Android Emulator 36.5 or later with API 31+ images that support virtual
Bluetooth. Start two disposable AVDs whose names begin with `Keepresso_`, then run
from the repository root with JDK 17 and the Android SDK configured:

```sh
python3 scripts/test-pairing-emulators.py \
  --adb "$ANDROID_HOME/platform-tools/adb" \
  --client emulator-5580 --peer emulator-5582
```

The script checks both explicit serials, virtual hardware and AVD names before
installing or clearing anything. It clears the client app's synthetic test data;
never select an AVD that contains a real pairing. Physical phones and unrelated
AVD names are rejected. Permission-granting instrumentation rules also reject
physical hardware before granting permissions.

The suite covers QR permission handoff, Activity recreation during that prompt,
visible invalid/expired-invitation feedback, canceled scans, pending local
approval, approval and denial, encrypted status, synthetic manual controls,
handover confirmation/cancel, notification deduplication and OK actions, reminder
settings, six-hour snooze and authenticated reconnect with the saved identity.
The harness briefly switches off only the validated peer emulator's BLE radio
to check disconnection, disabled controls and reconnect. Logs and a dashboard capture
are written under `android/app/build/emulator-results/`.

The SDK's `emulator/netsim` executable is located automatically next to the
explicit `adb` path; use `--netsim /path/to/netsim` if your SDK layout differs.
CI compiles the instrumentation APK; this two-emulator suite runs separately.

The camera activity result is supplied by the test. Optical QR decoding, actual
macOS approval/control adapters, real sleep, locked-phone/Doze delivery and FCM
are separate physical-device checks in [ACCEPTANCE.md](ACCEPTANCE.md).

## Sustained internet status

`TransportStateTest` exercises encrypted relay-batch processing directly in the
actual service, including immediate successful proof, transient read failure,
authorization rejection, expired evidence and a keepalive blocked behind a read.
It uses fixture keys and refused loopback connections, with no native adapter.

For an opt-in deployed-relay check, build both debug/test APKs and run:

```sh
python3 scripts/test-live-relay-emulator.py \
  --adb "$ANDROID_HOME/platform-tools/adb" --client emulator-5580 \
  --url https://your-relay.vercel.app \
  --mac-bearer /private/path/mac-bearer.txt \
  --private-dir /private/path/new-fixture-run --observe-seconds 120
```

This also clears only a validated disposable `Keepresso_` AVD. A synthetic Swift
Mac enrolls a temporary device, serves encrypted status and fake controls, and
revokes that device at the end. The observation checks reachability every500ms
through multiple foreground renewals, records maximum snapshot age and asserts
that a duplicate mutation executes once. It does not establish physical radio,
closed-lid, Keychain or completed-sleep behavior. Keep fixture reports private.

## Stale Android Bluetooth service caches

Some phones cache a Mac's GATT services across app restarts and omit the
advertised Keepresso service. The client attempts one cache refresh per
connection, only when the expected service/channels are missing, and delays
rediscovery briefly. Android exposes no public cache-invalidation API here:
`BluetoothGatt.refresh()` is an unsupported, guarded fallback. If it is absent,
restricted or ineffective, the app displays a retry instruction instead of
continuing with missing channels or looping. A service change during negotiation
invalidates that connection and outstanding callbacks; an existing authorization
can reconnect, while an unpaired phone must scan a fresh QR.

A separate opt-in `GattDiscoveryDiagnosticTest` can read public GATT UUIDs on an
already permission-authorized physical phone (`-e hardware true`, optionally
`-e refreshCache true`). It never pairs or sends controls. Normal emulator runs
do not execute it. Cache refresh is device-dependent; the emulator suite cannot
prove support on every Android vendor/version.

References: [virtual Bluetooth support](https://developer.android.com/studio/run/emulator-networking),
[service-change callback](https://developer.android.com/reference/android/bluetooth/BluetoothGattCallback#onServiceChanged(android.bluetooth.BluetoothGatt)),
[Android BluetoothGatt implementation](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/framework/java/android/bluetooth/BluetoothGatt.java).
