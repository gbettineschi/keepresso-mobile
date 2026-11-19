# Stable project signing implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task. Native/inline execution preserves the established method, with one fresh whole-branch review at the end.

**Goal:** Give certificate-signed Keepresso Mobile updates a stable privacy/consent identity and prepare safe project signing plus an unpublished two-build Mac trial.

**Architecture:** Derive reusable consent identity only from strictly validated running-code evidence and exact companion/certificate identity. Keep ordinary ad-hoc development builds conservative. Build and execute checks without production secrets, then sign on a fresh runner that never executes candidate code.

**Tech Stack:** Swift/Security/CryptoKit, Python unittest, shell codesign tooling, GitHub Actions environments.

**Spec:** docs/superpowers/specs/2026-11-18-stable-project-signing-design.md (owner approved 19 November 2026).

## Global constraints

- Only Keepresso Mobile Mac is changed; official Keepresso and all 114 pinned source files stay unchanged. Android identity/settings are preserved.
- Canonical installation `/Applications/Keepresso Mobile.app`, identifier `local.keespresso.companion`, Apple silicon/macOS14.5+ unchanged.
- No paid Apple account, production key creation/import, GitHub secret changes, certificate trust changes, real permission grants or power commands during code/tests. Production provisioning follows a concrete reviewed signing commit and owner authorization.
- One project self-signed identity, proposed ten-year validity. PKCS12 password at least eight characters; provisioning will generate 32+ random characters and never display it.
- Private key never enters repo, package, ordinary PR CI, artifact or log. GitHub environment is the primary store; no independent backup is presumed to exist.
- Keep legacy Apple/Keychain partition guarantees separate. A self-signed privacy identity is not notarization or a Keychain partition fix.
- Missing/invalid configured signer fails closed; never silently replace it or fall back to ad-hoc in project mode.
- Preserve folder/Steam resource scope, cancellation, worker consent bounds, unknown/denied status, pairing and private-file storage.
- Ordinary CI remains keyless. Only a trusted exact tag or owner-approved manual Mac candidate may reach the signing environment. Public artifacts expire after one day; $0 Actions spending unchanged.
- Deliver one atomic PR ready for review after the local trial; no automatic merge or public release in this task. If live owner permission checks are pending, leave a draft and name the gap.

## Review focus

- A metadata dictionary or certificate name without validated code must not create reusable authorization; exercise malformed/invalid/ad-hoc and changed signer/identifier cases in Task1.
- Parent and trigger worker must derive the same authority across updates, while folder and Steam configuration changes invalidate scope; test both consumers in Task1.
- A tampered or wrong-ID artifact must fail before signing; private keys and candidate execution must never share a runner; test in Tasks2–3.
- Manual trial must not trigger Android signing, publication or tap updates, nor allow arbitrary PR code to obtain production secrets; test event/mode/ref/SHA guards in Task3.
- Matching DRs alone do not establish TCC success; preserve granted/denied behavior and record real two-candidate acceptance separately in Task4.

---

### Task 1: Validated consent identity across builds

**Files:** create `macos/Sources/CompanionCore/CompanionPrivacyIdentity.swift`, `macos/Sources/KeepressoMac/CompanionAuthorizationIdentity.swift`, `macos/Tests/CompanionCoreTests/CompanionPrivacyIdentityTests.swift`; modify `TriggerFolderSetup.swift`, `TriggerObserver.swift`, `CompanionModel.swift`, `App.swift`; extend `CompanionSetupFlowTests.swift` / `TriggerFolderAccessTests.swift` / `CompanionSteamObservationTests.swift` as needed.

**Interfaces:** `CompanionPrivacyIdentity.make(bundleIdentifier: String, signingIdentifier: String, signatureValid: Bool, adHoc: Bool, certificateDER: Data?, legacyBuildIdentity: String) -> String?`; production `CompanionAuthorizationIdentity.current: String` (empty means unusable), backed by validated running Security code. Keep `buildIdentity` serialized field names compatible; their values become certificate-scoped only for a valid certificate signer.

- [ ] Write tests: same signer across different version/build/bytes yields the same `certificate-v1|identifier|SHA256(DER)` identity; changed signer or identifier never reuses it. Invalid signature returns nil. Valid ad-hoc preserves its exact legacy per-build identity; absent/malformed certificate evidence cannot masquerade as stable.
- [ ] Run new tests and observe RED, then implement pure derivation. Query running code via Security, validate dynamic and static signature, compare real signing/bundle identifiers, and take leaf DER from validated metadata. Do not infer trust from TeamID/name alone.
- [ ] Replace all parent/worker identity call sites, keeping the legacy executable hash only for valid ad-hoc fallback. Add read-only `--read-authorization-identity` before app model/transport/startup initialization.
- [ ] Add coverage that setup/folder/Steam consent carries across a same-certificate update but a changed folder/root/config/authority does not; prior ad-hoc records do not silently migrate to certificate identity.
- [ ] Run `swift test --package-path macos --no-parallel` (all pass), `swift build --package-path macos --product KeepressoMac`, upstream verification; commit.

### Task 2: Strict project signer and signing-only packaging

**Files:** modify `macos/scripts/sign-app.sh`, `test-sign-app.py`; create `macos/scripts/sign-candidate.py`, `macos/scripts/test-sign-candidate.py`, `macos/scripts/test-project-signing-integration.py`.

**Interfaces:** additive `KEEPRESSO_SIGNING_PROFILE=apple|project` (existing Apple default retained), exact `KEEPRESSO_CODESIGN_IDENTITY` SHA1, optional explicit `KEEPRESSO_CODESIGN_KEYCHAIN`; project mode requires a real configured identity and a default certificate-leaf-bound DR matching the exact companion ID. `sign-candidate.py INPUT_ZIP OUTPUT_ZIP --certificate-sha1 HEX --keychain PATH --source-sha HEX` only validates/extracts/signs/packages; never runs a candidate or build script.

- [ ] Write RED signer-contract tests for missing key, wrong profile, wrong ID/cert/DR, identifier-only/broad OR requirements, no ad-hoc fallback, explicit keychain, and preservation of the original Apple-only legacy checks.
- [ ] Implement project profile with signer-generated requirement, exact validation and no deep blanket re-signing. Keep deep strict verification. Reject unexpected nested executable code until an explicit inside-out policy supports it.
- [ ] Write RED signing-only packaging tests: bounded archive, no absolute/traversal/symlink/duplicate paths, single expected app/executable and correct identifier, wrong cert/invalid input refusal, exact ZIP output, no execution of candidate, private-key/material paths excluded. Implement with standard-library Python and injected command runner for fixtures.
- [ ] Add an explicit opt-in real integration fixture using only a temporary test keychain/one-day certificate. Build A/B with different bytes/versions, require mutual default-DR validation and equal read-only privacy identity, reject wrong signer and tampering, clean temporary material/search-list changes. Never grant TCC or trust.
- [ ] Run Python signer/package suites and the opt-in real fixture against a hidden staged keyless Mac bundle. Existing package self-check stays in the keyless build path. Commit.

### Task 3: Isolated release signing and Mac-only candidate delivery

**Files:** modify `.github/workflows/release.yml`; create `macos/scripts/ci-project-signing.py`, `scripts/tests/test_macos_signing_workflow.py`; update `docs/MAC_SIGNING.md`, `docs/releasing.md`, `docs/RECOVERY.md`.

**Interfaces:** existing dispatchable release workflow gains `mode=verify|mac-trial` (default verify), numeric version tag and expected exact commit SHA for manual signed trials. Keyless `macos` job uploads only its app ZIP; fresh `macos-sign` job uses `environment: macos-release`, strict repository/event/mode/ref/SHA guards and exact artifact/run identity. Tag publish depends on signed Mac output. Trial emits signed ZIP only, retention1 day, no publish/tap/Android.

- [ ] Write RED contract tests for mode/event/ref/SHA matrix, disabled signing on PR/ordinary verify, no Android jobs/secrets for Mac trial, fresh signing-only job, approved environment, candidate self-check only in build job, no artifact wildcard for key paths, unconditional cleanup and retention1 day.
- [ ] Implement an audited CI signer wrapper: require every configured secret, decode PKCS12 to a private temporary directory, import/unlock a temporary keychain scoped to `/usr/bin/codesign`, call signing-only packaging with exact signer, and always delete temporary material/keychain. Do not change login/system keychains or trust. Password is 8+ characters; actual provisioning chooses 32+ random characters.
- [ ] Wire separate keyless build/sign jobs and existing publication/tap needs. Reuse existing workflow path so branch dispatch can be tested before merge. Approval/protection rules and concrete source SHA are owner-controlled; never expose signing environment to PR triggers or arbitrary fork checkout.
- [ ] Document public self-signed/Gatekeeper limitations, one-time transition, secrets/backup custody, lost-key behavior, stable consent scope and exact trial acceptance. No production secrets or public tag is created by this task.
- [ ] Run contract + signer suites and workflow syntax validation with available tooling, plus keyless package/self-check. Commit.

### Task 4: Final review, provisioning handoff and local acceptance

**Files:** add local/private verification record and update the design status; one final PR description with generic LLM disclosure.

- [ ] Run full Swift suite, signer/package/workflow tests, `git diff --check`, `python3 scripts/verify-upstream.py`; require all relevant checks green and no credentials/activity logs in diff.
- [ ] Obtain one fresh whole-branch review on the most capable available model. Fix Important/Critical findings with failing tests then one fix pass; ledger all rulings and remaining minors.
- [ ] Prepare exact reviewed candidate/signing commit plus secret names/environment/provisioning commands for owner approval before creating the production certificate or secrets. Do not ask the owner to share a password in chat. Explain temporary generation, GitHub custody and optional encrypted independent backup.
- [ ] After authorization, provision the dedicated project identity/secrets, run owner-approved Mac-only signed candidate, verify signer/archive, install in place preserving pairing and one canonical app. Owner performs initial privacy approvals; never auto-reset or auto-grant permissions.
- [ ] Rebuild/reinstall a second different candidate with the same signer; verify running version/identity, no unneeded setup reset and actual relevant allowed/denied behavior. If privacy retention fails or extra trust is needed, report rather than adding trust.
- [ ] Create/update one Mobile PR, attach it to chat, wait required checks and mark ready only once local acceptance is established; otherwise leave draft with concrete outstanding check. Do not merge or publish a new public version.

## Execution ruling

The owner already approved this design and explicitly requested implementation in the existing session. Continue inline with the established single final independent-review method; do not add another routine approval/menu before writing tests. Key/environment provisioning and real permission checks remain distinct owner-controlled steps explicitly required by the approved design.
