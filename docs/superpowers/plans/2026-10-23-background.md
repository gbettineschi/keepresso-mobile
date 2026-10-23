# Keepresso Mobile Background Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement directly, with one fresh review after verification.

**Goal:** Correct Keepresso branding and provide the approved single-process background companion without a menu bar icon.

**Architecture:** A macOS-managed per-user app observes the running application list using KVO, including menu bar applications. A tested lifecycle gate starts/stops connections and timers without changing the saved choices. A normal settings window is reopened through Launch Services; a bundled Service Management agent starts hidden and recovers abnormal exits.

**Tech Stack:** Swift/AppKit/SwiftUI, ServiceManagement, existing Kotlin Android app.

**Spec:** ../specs/2026-10-23-background-design.md (approved in chat, including Finder/launcher reopening).

## Constraints

Keep the official app and 107 vendored files unchanged. Preserve all existing credential identities, signing keys, journals and the v1 protocol. Do not register a background item, enable Bluetooth, launch a normal helper, or perform real power actions during development. The Android product name is Keepresso; the Mac helper is Keepresso Mobile.

## Review focus

Detect LSUIElement app launch/termination through running-app KVO, rather than workspace launch notifications. Handle relaunches and repeated notifications without duplicate transports. Cancel a bounded trigger worker and reject stale async results on suspension. Preserve saved connection preferences. Respect explicit Quit, denied/disabled background approval, and reopening a hidden window.

## Task 1: lifecycle and cancellation

- [x] Add `NativeLifecycleGate` tests for cold absence, initial presence, duplicate identity, quit/relaunch, same PID/new launch, and stale generation rejection; observe RED before implementation.
- [x] Add a `BoundedWorker` cancellation test using a fake subprocess, observe RED, then support cooperative cancellation of the detached worker.
- [x] Implement the gate in CompanionCore and route `CompanionModel.updateNativeApplication(token:)` through start/suspend methods. Gate authorization, async results and timers; preserve defaults; cancel refresh work, close BLE and stop relay before going idle.
- [x] Run the complete Swift tests and record their results.

## Task 2: settings window and managed background item

- [x] Replace the status item/popover with one reusable normal settings window, hidden on close and reopened by `applicationShouldHandleReopen`. Keep `LSUIElement` and use accessory activation while hidden, regular activation while settings are open.
- [x] Observe `NSWorkspace.runningApplications` with initial/new KVO; derive a stable PID/launch-date token for the exact native app path and reconcile the gate.
- [x] Add an opt-in **Follow Keepresso** button using `SMAppService.agent`, actual approval status, and a Login Items settings link. Bundle a per-user LaunchAgent for this executable with `--background`, `SuccessfulExit: false`, and throttling. Never register it in a build or self-check.
- [x] Provide a separate explicit Quit button, teardown on termination, and a waiting message while native Keepresso is absent. Package and inspect the app, version 0.3.0, names, icon, plist and safe self-check.

## Task 3: documentation and delivery

- [x] Update the operator guide for window close/reopen, Follow Keepresso, explicit Quit, approval recovery and unchanged pairing; retain historical verification evidence.
- [ ] Verify the deployed relay branding and unchanged health/auth behavior. Correct the cloud alert and Firebase display names when the existing Google UI session permits it; never rotate credentials for a rename.
- [ ] Request one fresh code review of lifecycle, security boundaries and packaging, fix important findings, then run the relevant checks and publish a single CI update on the existing feature branch.
- [ ] Download the newly signed Android/Mac artifacts, verify versions and signing identity, and deliver them without replacing the user's running installation. Document physical-device and OS-registration acceptance checks as untested.
