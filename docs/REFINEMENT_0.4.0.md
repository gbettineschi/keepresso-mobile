# 0.4.0 trial verification

Keepresso Mobile now has compact battery/charging and CPU temperature, native-style trigger rows without private agent detail, generic check errors and a stable duration stepper. Ordinary readings update every2s nearby and roughly5s over internet while open. Trigger Check remains explicit and takes about4s locally, with an8s worker ceiling; it runs no permanent duplicate detector. Unknown rows use a question indicator because upstream readers cannot prove a negative. Manual/trigger semantics still match stock Keepresso.

The helper owns mobile routine reminders, stopped-but-awake warnings and one warning per known lid closure with verified system sleep disabled. It requests one Glass sound and best-effort trackpad feedback for that closure. Native Keepresso retains session control, safeguards and its optional local reminders. Mobile snooze affects routine reminders only. Urgent Android warnings use alarm audio, vibration and high importance; the owner may grant a Do Not Disturb exception. No automatic volume change, full-screen takeover or universal silent/DND guarantee is claimed.

Safe Sleep now stops/pauses and verifies native release before one normal system sleep request. A manually latched global closed-lid override must be released by the owner. The phone reports a request, not confirmed completed sleep. Every power test used injected/fake effects.

## Evidence

- 73 Swift tests,66 Kotlin core tests,18 relay tests; Android lint/build and Mac package/self-check pass.
- Full two-emulator suite: QR-result continuation and recreation, local approval/denial, real virtual GATT/encryption, reconnect, slow reads and one queued command, stale-intent cancellation, Sleep confirmation, urgent channel metadata and duplicate/resolved-warning handling.
- Six UI checks pass in each of light/dark; compact low-battery/thermal and Settings captures reviewed.
- Synthetic Bluetooth Start acknowledgement204ms. Two actual Android/Swift production internet runs: initial verification12.097s/10.381s, Start acknowledgement9.367s/7.029s. Duplicate ID caused one effect; Stop acknowledged; synthetic credentials revoked. These samples are not a latency guarantee.
- Internet fixture seeds synthetic pairing keys and uses deployed Vercel/Firestore with production Android service/crypto and Swift RelayCoordinator/MutationExecutor. No real native Mac power adapter. Expired encrypted fixture records/tombstones may remain for administrative cleanup; no real-device subtree was touched.
- Both review findings reproduced before fixes: unknown lid sample retaining an old open/pending baseline, and a new read response reviving a stale unsent command. Regression tests and the full suites pass after the fixes. No deferred minor findings.
- All107 pinned upstream files remain unchanged; official installed Keepresso binary hash unchanged.

## Owner acceptance / update status

The owner-signed Android0.4.0/code5 APK retains the installed signing identity and Firebase configuration. The phone was disconnected, so physical installation and pairing receipt are pending. Update with the APK or adb install -r; never uninstall/clear data to resolve a mismatch.

The canonical Mac bundle was updated to0.4.0. Startup is waiting on macOS Keychain authorization for the existing pairing keys; the agent cannot handle that prompt. A final build adding explicit startup-refresh guidance is packaged and hidden-staged, pending a graceful quit after the prompt. Do not treat the installed process waiting in Keychain as a healthy connection.

After final replacement, click Refresh Follow Keepresso if shown, then approve in Login Items if macOS asks. Locally ad-hoc signed builds may invalidate the old launchd signing requirement. Registration is refreshed only by the owner's click. Until this succeeds, automatic startup/crash recovery is not established. See RECOVERY.md.

Physical sleep, Mac sound/trackpad sensation, locked-phone FCM, real Bluetooth-to-internet handoff and actual DND/volume behavior still need the owner's deliberate tests. No successful build or FCM acceptance substitutes for them.

## Implementation decisions

1. Continue the existing dedicated feature checkout and authorized design; no extra checkout or design-approval stop. Cost: no additional checkout isolation; current scope was verified clean.
2. Use an8s bounded trigger worker rather than5s, with no permanent observer. Cost: a slow Check may wait longer; generic UI errors retain last successful assessment.
3. Coalesce Check and keep one unsent mutation waiting briefly behind reads; discard on stale status/route loss. Cost: the owner may need to tap again after interruption. Submitted uncertain mutations never resend.
4. Use2s nearby reads and5s cloud state/polls while active;60s foreground demand leases faster publication for65s. Fresh encrypted states maintain same-epoch reachability;15s freshness/security rules remain. Cost: first contact and commands can take seconds; cloud estimates are not guarantees.
5. Verify native stop, authorization and global-override release before normal sleep. Cost: manual global sleep overrides or unknown state block Sleep rather than silently changing unrelated settings.
6. Use isolated synthetic keys/fake effects for live relay acceptance; never control the real Mac or grant physical permissions in tests. Cost: physical acceptance remains pending.
7. Keep hardware, DND/volume, physical sleep and locked-phone receipt owner-run. Cost: no claim of universal audibility, haptics or receipt.
8. Keep ad-hoc update approvals explicit; add owner-click startup refresh and document Keychain recovery. Cost: some Mac updates require owner approvals; no automatic re-grant.

The upstream closed-lid menu-icon suggestion is drafted locally and remains unsent. Self-hosting, quotas and credential resets remain documented in SELF_HOSTING.md, QUOTA_ALERTS.md and RECOVERY.md.
