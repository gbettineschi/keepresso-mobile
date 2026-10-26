# Simple Mac settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Simple pairing controls and automatic, bounded startup registration with honest warnings.
**Architecture:** A tested main-actor registration coordinator uses a service adapter, read-only stale-build evidence and an injected handoff callback. SwiftUI derives its two pairing actions from explicit loaded/locked/paired state and reuses durable revocation.
**Tech Stack:** Swift, SwiftUI, AppKit, SMAppService, Swift Testing.
**Spec:** docs/superpowers/specs/2026-10-24-simple-settings.md

## Global Constraints

- Official Keepresso and 107 vendored files unchanged; no power, session or native preference effects in tests.
- Existing pairing/store identities retained. Do not delete real pairing or grant OS approvals during installation.
- Owner now authorizes production automatic startup registration and one known-stale repair; respect macOS requiresApproval even if user revoked consent.
- Canonical in-place Mac update; no second loose app. Android unchanged.

## Review Focus

- macOS consent revoked while the asynchronous job probe is pending: no unregister/register.
- repeated activation or concurrent refresh: at most one registration/repair per foreground process.
- failed unregister or shutdown during it: no subsequent register.
- unavailable keys are never presented as unpaired or eligible for deletion/new QR.
- old multiple-phone records remain protected; Delete confirms all affected records; no test deletes real keys.

### Task 1: Automatic startup
- [x] RED coordinator tests for initial registration, denied/revoked approval, stale repair, healthy no-op, duplicate refresh, failure and shutdown.
- [x] Implement CompanionCore coordinator and real SMAppService adapter; remove Enable/Refresh buttons; Open Login Items only, warning status.
- [x] GREEN targeted and full Swift tests. Document updated owner authorization in AGENTS and recovery docs.

### Task 2: Pairing and installed update
- [x] RED tests for locked/loading/unpaired/paired action exclusivity and unavailable/native-off gating.
- [x] Consolidate SwiftUI pairing section, two contextual buttons, confirmed deletion via existing revocation, one new pairing slot.
- [x] Full tests, unchanged upstream and package/self-check/signature. Review once with fresh context; fix material findings with regression tests.
- [x] Bump Mac version, package ZIP, graceful in-place update; preserve keys/settings/native binary. Verify real startup state without approving dialogs; owner handles Keychain if needed.
- [ ] Update reports and existing PR, push once, verify CI.
