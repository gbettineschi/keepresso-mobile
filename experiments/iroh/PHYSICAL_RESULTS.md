# Real-phone iroh trial — 30 October 2026

**Final result: 36 phone checks and 18 emulator regression checks passed.**
The physical device was a Samsung S23 (SM-S911B). Both endpoints used the pinned
iroh-ffi 1.2.0 packages and the existing application authentication/encryption
code, with synthetic keys and fake status only.

| Environment / profile | Checks | Selected path at measurement | Median round trip | Maximum observed |
| --- | --- | --- | --- | --- |
| Phone Wi-Fi / automatic | 9 passed | IP | 49 ms | 1,300 ms |
| Phone Wi-Fi / forced relay | 9 passed | Relay | 55 ms | 157 ms |
| Phone cellular / automatic | 9 passed | IP | 45 ms | 298 ms |
| Phone cellular / forced relay | 9 passed | Relay | 78 ms | 167 ms |
| Emulator / direct | 9 passed | IP | 11 ms | 5,017 ms |
| Emulator / forced relay | 9 passed | Relay | 43 ms | 184 ms |

Each profile included thirty authenticated status round trips, twenty fresh
endpoint reconnects using the same synthetic authorization, unknown-device and
wrong-key rejection, encrypted-record replay rejection, oversized-frame and
expired-request rejection, refusal of mutation requests, and a fresh connection
while an older authenticated connection remained idle. Four additional CLI
device-selection/path guards passed without invoking adb.

These timings measure synthetic request/response after authentication, including
the existing application encryption. They exclude initial connection setup and
real Keepresso status/trigger collection. The selected path is iroh's snapshot
after the thirty responses; it does not classify every preceding packet. The
forced-relay profiles bind both IPv4 and IPv6 UDP to loopback and assert the
selected relay path, preventing a silent direct-path substitution.

USB was confirmed as `sec_charging,adb`, with tethering off. The owner manually
disabled phone Wi-Fi for the cellular test, left the Mac's connection unchanged,
and the app reported `cellular` during both final cellular measurements. No adb
forward/reverse tunnel carried the test protocol. This establishes a successful
direct Internet path in this particular cellular/Mac network combination, not a
general NAT-traversal success percentage.

## Diagnosis retained with the result

The first complete phone automatic-profile run failed seven of nine cases with
timeouts. Focused status cases could work, and a later twenty-reconnect case also
passed, so the failure was not treated as deterministic loss of Internet access
or a cryptographic bypass. The relay-only complete suite passed independently.

Inspection found that the experimental Mac accept loop still awaited an incoming
TLS handshake before accepting the next peer. The revised fixture delegates the
accept loop and parallel TLS handshakes to iroh's native Router through
`EndpointOptions.protocols`; the Swift handler retains its application-level
authentication, four-session cap and twenty-second session bound. The final
complete Wi-Fi run and emulator regressions passed after that change. This is a
correction to the prototype, not proof that every earlier timeout had the same
cause or that the installed companion's old reachability issue is fixed.

The first cellular attempt was interrupted: the owner reported that webpages
also failed, and the adb instrumentation command ended with exit code 255. It
provided no cellular acceptance result. After the owner restored connectivity,
the fresh cellular retry passed both complete profiles. No phone network/VPN
settings were changed by the runner.

The direct-path latency outliers above remain relevant. In this observation
window relay timings were more consistent; the run does not establish an absence
of stalls, long-duration reliability, or a battery/energy advantage.

## Preserved installation and remaining scope

Only the separate `.irohtrial` package and its instrumentation package were
installed on the phone. Both temporary packages were removed after testing.
Package inventory then showed only the original Keepresso Mobile, still version
0.5.2 / code 5002. Its data, pairing, permissions and signing identity were never
reset or replaced. The installed Mac companion, official Keepresso, cloud setup,
and all production source/configuration paths remain unchanged. The upstream
digest check still verified all 107 pinned files.

This remains a throwaway connectivity trial. It has not migrated either app to
iroh, removed Vercel/Firebase, exercised real power/session commands, validated
background alerts, tested lid/sleep/wake, or switched Wi-Fi/cellular during one
live connection. The idle-old-connection case tests concurrent reconnect handling,
not live network migration. The ticket was supplied by the diagnostic runner;
production enrollment/discovery and revocation still require integration work.

See [portable measurements](PHYSICAL_RESULTS.json), [build/run guide](README.md),
and the ignored `.run/` directories for local diagnostic output. Portable results
exclude serial numbers, endpoint tickets, IP addresses, SSIDs and private credentials.
