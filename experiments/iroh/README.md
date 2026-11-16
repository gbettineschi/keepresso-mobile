# iroh connectivity trial — throwaway, not app integration

Authorized 30 October 2026 after the iroh/WebRTC comparison. This experiment
answers whether the published Swift and Android bindings can carry our existing
encrypted protocol. It does not change either installed app or the Vercel relay.

The Mac command-line fixture and a separate, emulator-first Android package use
**public synthetic device keys and fake status**. They reuse `ServerHandshake`,
`SealedChannel`, `CommandRequest`, and Android `ClientSession` from the app's core.
No installed credential store, native Keepresso adapter, real readings, power
operation, login item, background service, or permission request is used.

## Pinned dependencies

- `iroh-ffi` Swift package **1.2.0**, with the upstream checksummed xcframework.
- Maven Central **computer.iroh:iroh-android:1.2.0**, the Android AAR, not the
  desktop JVM artifact. Native library loading uses `IrohAndroid.installAndroidContext`.
- Kotlin 2.2.21 is confined to this experiment. Production's Kotlin and Swift
  package definitions remain unchanged.

The current website's Kotlin tutorial still says Android needs a source build.
Inspection of the actual 1.2.0 release and Maven package showed an Android AAR.
No Rust/NDK build is needed to consume that package. Swift requires macOS 14.5+
and the prebuilt Mac slice is Apple silicon only. These are integration
constraints to settle before adopting iroh in the production companion.

## Build

Use the existing Android SDK with platform 35, JDK 21 to run Gradle, and a
discoverable JDK 17 for the existing core's toolchain. Keep SDK paths in local
environment variables or `android/local.properties`, not in Git.

From the repository root:

```sh
swift build --package-path experiments/iroh/swift -c release
cd experiments/iroh/android
../../../android/gradlew :probe:assembleDebug :probe:assembleDebugAndroidTest
```

## Run on an emulator

```sh
python3 experiments/iroh/run.py --sdk "$ANDROID_HOME" --serial emulator-5584 \
  --avd Keepresso_API36 --avd-home /absolute/path/to/test-avds
```

The runner can reuse a running emulator or start the supplied AVD headlessly in
read-only mode. It verifies that the target is an emulator, installs only the
separate test package, runs both paths, and stops processes it started. By default it never
selects the attached physical phone. This package has no launcher entry.

Two modes run the same nine cases:

- **Direct:** relay disabled; the ticket contains Android emulator's host alias.
  This tests cross-platform direct UDP, not LAN discovery or Internet hole punching.
- **Relay:** public iroh relay, no direct address in the ticket, and UDP bound to
  each device's IPv4 **and IPv6** loopback only. Assert the selected traffic path is a relay. This
  isolates fallback without modifying host networking or firewall settings.

Cases cover 30 encrypted status responses with matching request IDs, twenty fresh
connections using the same authorization, unknown device rejection, wrong-key
rejection, encrypted record replay rejection, oversized-frame rejection, expired
request rejection, and refusal of mutation commands by the read-only fixture.
The ninth case leaves an authenticated old transport idle and checks that a new
authorized transport can authenticate and read status within four seconds. The
fixture accepts at most four concurrent sessions, each bounded to twenty seconds.

Initial diagnosis caught two mistakes in the experimental fixture: binding only
IPv4 left the default IPv6 route available, so a supposedly relay-only test could
upgrade to direct; and serial acceptance blocked reconnects behind an idle old
connection. A focused idle-connection test failed before bounded concurrent
acceptance was introduced. These changes are confined to this fixture.

The real-phone extension additionally uses iroh's native `Router` via
`EndpointOptions.protocols`. The router handles incoming TLS handshakes in
parallel; the Swift handler retains the four-session cap, twenty-second session
bound and existing application authentication. This replaces the earlier custom
accept loop, which still awaited a TLS handshake before accepting the next peer.
See the [upstream router](https://github.com/n0-computer/iroh/blob/main/iroh/src/protocol.rs).

The Android packaging excludes unused desktop binary resources from the JVM JAR;
the AAR's Android native libraries remain included and exercised by the tests.

## Authorized physical-phone trial

Only after the owner authorizes their connected phone, supply that exact serial
and the separate opt-in flag. The default runner still refuses physical devices.

```sh
python3 experiments/iroh/run.py --sdk "$ANDROID_HOME" \
  --serial YOUR_PHONE_SERIAL --physical-device --run-label phone-wifi
```

This installs only `io.github.gbettineschi.keepressomobile.irohtrial` and its
instrumentation package. It does not update, stop, clear, read pairing from, or
uninstall Keepresso Mobile. No runtime permissions are granted by the runner.
The physical device must already be connected and authorized; no other device
is selected as a fallback.

Physical mode runs **auto** plus **relay**. Auto uses the real endpoint's current
addresses and relay, not the emulator host alias. Its selected IP/relay path is
recorded as observed; a direct connection is not assumed. Relay mode retains the
strict loopback-only socket configuration and relay-path assertion. Measurements
include a coarse phone network type (Wi-Fi/cellular/other), never SSID or IP address.
Results are saved in the ignored `.run/<run-label>/` directory. `--mode auto` or
`--mode relay` selects one profile.

For a separate cellular check, have the owner turn phone Wi-Fi off, keep mobile
data on, and leave the Mac's connection unchanged. Confirm USB tethering is off
before interpreting a direct connection as Internet NAT traversal. The runner
never toggles Wi-Fi, cellular data, tethering, Bluetooth, screen lock, or power.
Use another result label, such as `phone-cellular`. Background operation, actual
network switching, and sleep/lid behavior need their own acceptance checks.

The runner bounds startup and test time, cleans up the public endpoint ticket,
and writes results under ignored `.run/`. Logs exclude keys, decrypted records,
real activity and private readings. The default iroh preset contacts its public
lookup/relay infrastructure; no paid service account or diagnostics upload is used.

## What this cannot prove

Passing is a binding/protocol feasibility result. It does not establish cellular
NAT success, automatic network handover, sleep/wake or closed-lid reliability,
background Android/iOS delivery, battery impact, or a secure production migration.
Memory/CPU samples describe only the isolated idle fixture, not the full app.

A retained implementation needs a separate reviewed design: authenticated
endpoint-ID enrollment through the existing pairing, revocation, route ownership,
fresh status before enabling controls, no retry of uncertain mutations, global
deduplication, lifecycle/sleep handling, and a separate background push path.
The working BLE/Vercel paths and phone pairing remain intact during this trial.

Sources: [Swift binding](https://docs.iroh.computer/languages/swift),
[Android package](https://repo.maven.apache.org/maven2/computer/iroh/iroh-android/1.2.0/),
[pinned release](https://github.com/n0-computer/iroh-ffi/releases/tag/v1.2.0).
