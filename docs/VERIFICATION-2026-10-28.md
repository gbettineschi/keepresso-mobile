# Nearby v2 / private storage verification — 28 October 2026

Prepared trial: macOS0.5.0/build13, Android0.5.0/code5000. Source implementation: d1ed235, f9cc094,029a7e8,232d3ec,a9103cd. No installation on the owner's devices or release publication was performed during this verification.

## Automated results

| Check | Result |
| --- | --- |
| Swift core, storage, command authority and relay tests |138 tests /28 suites, all pass |
| Kotlin protocol, transport, freshness and deduplication |83 tests, all pass |
| Two dedicated Bluetooth emulators |31 instrumentation tests, all pass |
| Exact retained-signer, non-debuggable packaged APK |Approval/encrypted dashboard/fake controls/reminders/radio-loss/reconnect and background phone-radio return pass |
| Sustained nearby foreground/background/foreground |65seconds;130samples; zero unreachable; max snapshot age10.114seconds |
| Synthetic command acknowledgement |348ms in full development run; this is not a physical latency guarantee |
| Android release lint |0errors;22existing warnings |
| Mac release build, strict ad-hoc signature, safe self-check |Pass; no normal app launch, power or credential access |
| Original KeepressoCore source integrity |107 byte-identical upstream files verified |

Permission denial retains fixture pairing/Internet configuration. A separate bounded recovery policy handles startup/advertising failures and radio return without fake disconnects. New emulator cases keep the phone adapter off for25seconds, then verify retained-pairing authentication without foregrounding, both at startup and after an established session. The exact final release APK also passes the connected-radio/background-return case. The emulator flow covers QR handoff/recreation, local approval/denial, encrypted traffic, one queued control behind a slow read, radio-loss reconnect, synthetic sleep confirmation and urgent-warning deduplication. Synthetic controls alter fixture data only. JVM/Swift tests reject bad proofs, tampered/replayed messages, stale epochs and duplicate mutations; interrupted commands remain uncertain and are never replayed over another route.

An existing persistence failure was reproduced while the host was already screen-locked: `completeFileProtectionUnlessOpen` allowed writing a new journal but denied reopening it. Disposable probes isolated this exact step. Journal/outbox writes now use [protection until first user authentication](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionuntilfirstuserauthentication), so they remain usable in the background after login. Owner-only0600 modes, atomic writes, full durable sync and reservation-before-effect remain. All138 tests passed in that locked state; tests did not lock/unlock or control the actual Mac.

Existing Command Line Tools linker/deprecation warnings and Android dependency/style warnings remain. They are not recorded as clean warning output.

## Prepared artifacts

| Artifact | SHA256 |
| --- | --- |
| Keepresso-Android-0.5.0-development.apk |`114fdeba297fd1f6c5eec314894393cb946ca48e8c18c2d6636457caa7808955` |
| Keepresso-Mac-0.5.0-arm64-development.zip |`37b97db961355c7e6f5c4d2657a48be0b6214ba13cfd50fdea952db01656c07c` |

Android preserves package `io.github.gbettineschi.keepressomobile` and signer SHA256 `166dd4da449dcccaa1e4e1b881bf77455c38f6633809aeba53480034a0b2395d`; all four expected public Firebase client values were verified in the APK. No Firebase server key is an app build input. The Mac archive preserves bundle ID `local.keespresso.companion`, has no menu bar item and uses the existing free ad-hoc signing path.

## Pending owner-device acceptance

After the phone is reconnected, update both apps in place and preserve pairing. The existing Mac Keychain records may require one final owner-approved migration to the private file. Subsequent valid-file launches bypass Keychain entirely. Test actual Mac/Samsung discovery, continued QuickDrop/Tetherbug use, sustained fresh status, locked-phone/background delivery, and owner-controlled sleep/wake/lid-close behavior. A real sleeping Mac should become Unreachable; a disconnect alone does not prove sleep. No new deployed-relay end-to-end result is claimed here; existing relay-state tests passed and the deployed configuration was unchanged. Safe remote sleep remains unsupported by the native adapter.

The installed companion remained0.4.9 during preparation; official Keepresso was unchanged. Private storage/recovery and the accepted same-user access boundary are documented in [RECOVERY.md](RECOVERY.md).

## Physical trial update: Android0.5.1 / Mac0.5.0

The first owner-device run exposed a shared-GATT case absent from fresh emulator pairing: Android reported existing physical connections before this service was published. Selecting the first CONNECTED callback blocked this service's actual subscriber. Commit2435817 selects only a valid CCCD enable on the current notification characteristic, ignores unrelated physical connections/disconnects, rejects competitors without cancelling their shared link and retains bounded pre-subscription MTU metadata. A callback-replay instrumentation regression failed both cases on the previous code and passes after the fix. The complete suite now passes92JVM tests and33instrumentation tests; release lint reports0errors/22existingwarnings.

The retained-signer, non-debuggable Android0.5.1/code5001 APK was installed in place. SHA256: `128e2c89989e7093fa93e644f23fbe364d7ce161c2e61e7b4b1c9b730aca587b`. Both Bluetooth permissions remain granted, and the connected-device foreground service is active. No owner app data was cleared or new QR pairing requested. The Mac remains0.5.0/build13 at its canonical Applications path; official Keepresso's binary and source are unchanged. QuickDrop was left running; no other app or global Bluetooth setting was changed.

Actual phone observations:182.6seconds,25visible Awake/Nearby samples and25distinct fresh update times, zero authentication drops, timeouts, validation failures or Unreachable samples. A further65.6-second window-close run produced9fresh Awake/Nearby samples and zero failures. These are bounded observed results, not an indefinite reliability guarantee. Both Internet and nearby authenticated on the updated phone during startup, then nearby became preferred. The explicit reverse handover check could not be completed after USB was disconnected; lid-close/sleep/wake acceptance remains pending. Nearby was restored enabled and the companion was left running hidden (accessory activation policy), with its saved pairing and Internet fallback retained.

The Mac's legacy connection migrated to the owner-only private file; metadata checks confirmed0700directory/0600regular single-link file/current owner/bounded size without the agent reading its contents. A subsequent normal Quit/reopen restored the same phone and Internet configuration without another Keychain recovery action. No paid signing account or Keychain ACL widening was used.
