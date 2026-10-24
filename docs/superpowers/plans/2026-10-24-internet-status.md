# Internet status implementation plan

**Spec:** docs/superpowers/specs/2026-10-24-internet-status.md

Use the existing dedicated feature checkout. Implement inline with test-driven development and one final fresh review. No installation or production startup/pairing/power changes during this task.

### Task 1: Mac measurement and shared contract
- [x] Add failing tests for route versus internet proof, failed checks, stale data, coalescing and obsolete results; add protocol validation cases.
- [x] Implement bounded HTTPS probe and lifecycle-bound network adapter; optional current SSID permission action, no coordinate reads.
- [x] Extend the optional snapshot fields and document their semantics. Run Swift and Kotlin core suites.

### Task 2: Android presentation and reviewable packages
- [x] Add failing emulator assertions for Online, Offline with associated Wi-Fi, Check failed, Checking, hidden/long SSID, missing fields and stale evidence.
- [x] Add compact facts row, preserve last-known dashboard behavior and controls.
- [x] Run emulator checks light/dark, inspect screenshots, run lint/build, verify pinned source and package identities. One fresh review, fix material findings with tests.
- [x] Stage Mac ZIP and Android APK, publish only local review artifacts. Record evidence and wait for owner approval before either installation.

**Review focus:** Internet is measured on the Mac, not inferred from nearby authentication; route changes/late completions cannot reuse Online; probe failure cannot claim proven offline; SSID permission is optional and never requested at startup; no production install or live power/startup effects in tests.
