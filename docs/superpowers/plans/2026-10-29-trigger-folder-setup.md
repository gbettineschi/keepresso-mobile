# Trigger folder setup implementation

Spec: docs/superpowers/specs/2026-10-29-trigger-folder-setup-design.md
Use subagent-driven-development for one isolated coupled Mac task, review then root delivery.

## Global Constraints
No real owner folder reads/permission grants or native/power settings from tests. No vendor edits; inject DownloadFolderScanning. No pairing/credential/signing/cloud reset. No automatic trigger scans or remote permission prompts; default-deny folder reads unless exact current-build local consent. Existing historical results/bounds/auth remain.

### Task 1: Foreground setup and worker gate
Files: new CompanionCore policy/tests; KeepressoCore/Adapters permission-gated scanner/tests; new KeepressoMac folder setup controller; App.swift section/pair action/worker arguments; CompanionModel.swift pairing preparation; TriggerObserver.swift scanner input. Root owns versions/build/plist usage description/packaging.
- RED policy/scanner tests for no read before consent, configured-only/exact URL/build boundaries, denial/retry/new folder/new build, no engine/power construction, pairing continues after denial.
- Add minimal setup UI before pairing, explicit local probe, QR preparation and recovery. Gate worker's real scanner through validated consent passed in scratch/args; never trust arbitrary worker input beyond canonical configured rule folders/current identity. Unknown skipped rules preserved.
- Focused/full Swift tests, signed commit and report. No subagents, owner runtime/emulator/cloud operations.

### Task 2: Root review and delivery
- Scoped task review, integrate, version Mac0.5.3/build15 and purpose text, build strict verify/self-check. Android0.5.2 unchanged.
- Update canonical Mac app after graceful Quit; preserve keys/config. Owner handles local Allow and macOS prompt; observe phone explicit check and retained result, don't grant on their behalf. Document verified versus pending boundaries.
