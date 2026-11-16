# Android pairing regression tests

The two-device emulator harness exercises the Android app through real virtual
Bluetooth GATT, framing, authorization proofs and authenticated encryption. The
second emulator is a synthetic Mac central; the production phone advertises the v2 service and remains the logical authentication client. The fixture is not a connection to macOS.
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
settings, six-hour snooze and authenticated reconnect with the saved identity. A65-second foreground/background/foreground observation checks continuously fresh nearby status and retained pairing; slow-read tests check queued controls and one effect. `--case startup-recovery` and `--case phone-radio-recovery` hold only the validated phone emulator's adapter off for25seconds, then check background recovery with retained keys; both also run in `--case all`.
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

## Version and permission boundaries

From0.5.0 the phone no longer scans or uses the unsupported `BluetoothGatt.refresh()` cache workaround. Both apps use new v2 service UUIDs and must be updated together. Production Android requests CONNECT + ADVERTISE on API31+, without SCAN or Location. Only the synthetic central test adopts SCAN + CONNECT + Location through instrumentation after its emulator guard; those permissions are not requested by the installed phone app. Denied advertising is exercised with fixture authorization and Internet settings retained.

Virtual GATT success does not prove Mac Core Bluetooth discovery, Samsung background policy or coexistence with other sharing apps. Test those on the owner's devices after reconnection without resetting pairing or stopping those apps.

## Shared physical GATT callbacks

`SharedGattConnectionTest` replays public connection callbacks observed before service publication on the real phone, with an emulator-only fake BluetoothDevice and the actual transport callback. It verifies that a generic connection is not a subscribed peer and an unrelated disconnect cannot stop this server. The test waits for asynchronous advertisement registration before cleanup so a late platform publication cannot contaminate the next virtual GATT flow. Ownership, selected-only MTU, bounded unclaimed metadata, duplicate/competing subscriptions and stale-generation behavior are also covered by17focused core tests. Physical acceptance remains distinct from replaying callbacks.
