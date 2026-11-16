# iroh trial results — 30 October 2026

This records the first emulator stage. For the later real-phone checks and
updated fixture, see [physical-device results](PHYSICAL_RESULTS.md).

**Result: feasible across native Swift and Android, including the public relay.**
This is an isolated protocol experiment, not an installed app integration or
acceptance of real-phone sleep, lid, handover, or background behavior.

Final run started at 09:22:04 UTC. See [machine-readable measurements](RESULTS.json)
and [reproduction instructions](README.md). Both packages used iroh-ffi 1.2.0;
Swift resolved revision `66a8d619a4d791d458d582f312df6e0ab42bc541`.

| Check | Direct UDP | Public relay |
| --- | --- | --- |
| Instrumentation cases | 9 passed | 9 passed |
| Fresh reconnects with the same synthetic authorization | 20 passed | 20 passed |
| Encrypted status round trips | 30 passed | 30 passed |
| Median status round trip | 10 ms | 60 ms |
| Maximum observed status round trip | 147 ms | 147 ms |
| Selected path asserted by the test | IP | Relay |
| New connection while old authenticated session stays idle | Passed within 4-second bound | Passed within 4-second bound |

The timings include the synthetic request/response and our existing application
encryption after authentication. They exclude initial connection setup and real
Mac status collection. This is one emulator/host environment and one observation
window, not a network-wide latency or reliability estimate, or a WebRTC comparison.

The other cases rejected unknown devices, wrong pairing keys, replayed encrypted
records, oversized frames and expired requests. A validly encrypted sleep request
was explicitly refused by the read-only fixture. No real Mac control adapter was
created, so a test cannot issue a native sleep or Keepresso command.

## Corrections established during the trial

- The website's Kotlin tutorial says Android needs a source build. The actual
  published `computer.iroh:iroh-android:1.2.0` AAR supplies the native Android
  library and initialization API. Neither Rust nor the NDK is needed to consume it.
- An IPv4 loopback bind does not replace the default IPv6 socket. The first
  relay-enabled run communicated successfully but failed the relay-path assertion
  after finding a direct path. Restricting both families made the fallback test
  exercise the relay. Host networking and firewall settings were never changed.
- An earlier repeated direct run stalled during reconnect. The fixture's serial
  acceptance was a concrete blocking mechanism: a focused test with an old idle
  session failed at four seconds, and the trace showed no second accepted session.
  Bounded concurrent acceptance corrected that reproduction. The final complete
  run passed it on both paths. This is a fixture correction, not evidence that
  the installed companion's previous reachability issues are fixed.
- The shared JVM dependency carried unused Windows/macOS binaries into the APK.
  The trial excludes those desktop resources while retaining and exercising its
  Android native libraries. The final standalone debug APK was 25,072,718 bytes;
  its Android iroh library was 12,831,624 bytes. These are not incremental sizes
  for the production app, and no optimized release-size comparison was made.

During five one-second idle samples, the Mac fixture's resident memory was
13.0–16.0 MiB in direct mode and about 21.3 MiB with the relay. Its cumulative
CPU-time counter stayed at 0.08 seconds across the relay samples. These short
fixture samples are not steady-state, full-app, Android battery, or energy tests.

## Preserved state and remaining decisions

- Both installed apps, real pairing, private credentials and cloud configuration
  were untouched. The owner's attached phone was never selected for installation
  or instrumentation. The disposable emulator and fixture were stopped afterward.
- All production source/configuration paths remain unchanged on this branch;
  the 107 vendored upstream files still pass their original digest verification.
- Swift's prebuilt library requires Apple silicon and macOS 14.5+. Production
  currently targets macOS 14.0+, so compatibility needs a deliberate build choice.
- Production still needs endpoint identity enrollment through the existing paired
  channel, revocation, one route owner, shared command deduplication, freshness
  gates, sleep/wake lifecycle and no uncertain mutation retries.
- BLE remains useful without Internet. iroh public relays have no uptime guarantee;
  paid hosting or self-hosting are separate choices, not enabled by this trial.
- Background notifications remain separate. No Vercel/Firebase service has been
  removed or replaced, and no production migration is represented as completed.
- Cellular NAT traversal, changing networks, real-phone idle power, lid/sleep/wake,
  long-duration operation and future iOS background delivery remain untested.

Retaining this prototype as production code requires an integration design and
review. It currently stays isolated on `spike/iroh-connectivity`.
