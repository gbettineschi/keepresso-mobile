# Guided setup and all-trigger assessment implementation plan

> REQUIRED: subagent-driven-development; independent new-file tasks may use dispatching-parallel-agents with fixed interfaces below.

Goal: automatic simple Mac setup and generic assessment of all20pinned native trigger types.
Architecture: audited input adapters feed the unchanged factory; independent guided permission coordinator runs only in foreground; bounded optional Steam proof joins existing folder proof. Root wires existing app/worker.
Spec: docs/superpowers/specs/2026-10-29-guided-setup-all-triggers-design.md

## Global Constraints
- No vendor Sources edits, owner/power/settings/grant/cloud operations or real owner probes in tests. No keys/signing/pairing reset.
- Engine only explicit Check;8child/12parent/14relay/25phone/15auth/30request remain. No activity details or unsafe negatives.
- All20cases explicit; source-compatible pinned1.27.0 matching. Unknown is for unavailable/insufficient input, not a four-case whitelist.
- Tasks own disjoint NEW files; existing app/worker/model/build wiring is root-only. No subagents from workers; isolated worktrees, signed commits/reports.

## Shared Interfaces (fixed)
A: public final class CompanionObservationInputs in KeepressoCore/Adapters. init(hookRecords:@escaping @Sendable(Date)->[AgentHooks.HookRecord],hooksAvailable:@escaping @Sendable()->Bool,folderApproved:@escaping(URL)->Bool,steam:SteamDownloadMonitoring,steamAvailable:@escaping()->Bool,now:@escaping()->Date=Date.init). Expose public var factory:TriggerFactory and public func assessed(_ state:RuleState)->Bool?. Fakes may use additional injected dependency initializer.
C: public struct CompanionObservationConsent in CompanionCore with public static func encode(folders:Data?,steam:Data?)->Data? and decode(_ data:Data?)->CompanionObservationConsent?; public let folders:Data?,steam:Data?. Versioned typed format and total max32768bytes; invalid/missing defaults no grants.
C: public final class CompanionSteamObservation:SteamDownloadMonitoring in KeepressoCore/Adapters. public init(buildIdentity:String,consentData:Data?); public var isDownloading:Bool; public var hasCompleteReading:Bool. public static func prepareConsent(buildIdentity:String,folderProbe:@escaping(URL)async->Bool)async->Data? and public static func isPrepared(_ data:Data?,buildIdentity:String)->Bool (metadata only). Extra injected file-driver APIs for tests permitted.
B: @MainActor final class CompanionSetup:ObservableObject and CompanionSetupView in NEW Mac files. init(rules:@escaping()->[TriggerRule],buildIdentity:@escaping()->String,requestFolders:@escaping()async->Bool,foldersReady:@escaping()->Bool,requestSteam:@escaping()async->Data?,steamReady:@escaping(Data?)->Bool). Expose @Published var presented:Bool, read-only running:Bool, steamConsent:Data?; func presentIfNeeded(),review(),start()async,deferSetup(),finish(). New view takes setup and onFinished callback; root calls after managed foreground startup settled. Safe framework status queries allowed at foreground evaluation, actual requests only after Continue. Injectable storage/permission drivers for tests.

### Task 1: Generic audited observation inputs
Own NEW KeepressoCore/Adapters/CompanionObservation*.swift (excluding CSteam), new focused tests only; may fix thread-safe failed getter in StrictObserverSettings.swift. No existing TriggerObserver/App/Model edits.
- [ ] RED coverage fixtures for20types through unchanged factory, positive and inactive/unknown per proof; missing permission/read failures/cold samples. No actual sensors/apps/process lists in tests.
- [ ] Build CompanionObservationInputs exact interface. Inject audited protocol wrappers, preserve pinned matching/EMA/grace. Track completion atomically for async process/VPN/calendar caches (fetch completion alone must not prove an old cache is ready). Use native helper APIs/internal module functions where appropriate.
- [ ] Input/readiness paths cover power, display, SSID, app, process, time, volume, CPU, media/mic/audio, VPN, Bluetooth, calendar, gaming, throughput, folder download, agents, controllers, Steam. No unused inputs read; skip gated location/BT/calendar/folders. No capture/recording permission.
- [ ] Existing folder approval closure gates an error-aware metadata scanner; denied/no permission unknown, genuine empty read can establish inactive. Agent hook copies stay disposable. Conservative cold-agent negative limits explicit, no artificial class whitelist.
- [ ] Focused/full Swift tests, signed commit/report. Root wires worker loop to assessed for every state.

### Task 2: Safe Steam observation proof and consent envelope
Own NEW CompanionCore/CompanionObservationConsent.swift, KeepressoCore/Adapters/CompanionSteamObservation.swift, focused new tests. No existing folder/worker/app/model edits.
- [ ] RED codec/bounds/default-deny and fake filesystem/permission prep/Steam fixtures. No owner Steam or home reads; default paths may be calculated only.
- [ ] Implement exact shared interfaces. Local prepare probes default steamapps before reading VDF, discovers/probes exact libraries, binds proof to executable identity, parsed roots and configuration fingerprint. Blocking reads detached from caller MainActor. Denied or missing inputs no proof.
- [ ] Worker first validates identity/proof and fixed base grant; reads only base configuration then verifies fingerprint/current parsed roots before touching recorded libraries. Config changes/unapproved root/invalid data return unknown. Use native SteamDownload parsers/flags/recency semantics, no downloaded-content reads. Bound sizes/files/walk and preserve partial-positive vs incomplete-negative truth.
- [ ] Versioned envelope fits existing32768byte scratch transport; malformed/oversized defaults deny; no folder paths in args/logs.
- [ ] Focused/full Swift tests, signed commit/report.

### Task 3: Automatic guided setup coordinator and view
Own NEW Core/CompanionSetupFlow.swift, Adapters/CompanionSetupRequirements.swift, Mac/CompanionSetup.swift, Mac/CompanionSetupView.swift, focused tests only. No existing App/Model/FolderSetup/Worker/build edits.
- [ ] RED fake flow tests: foreground auto presentation only, one Continue sequential requests, authorized skip/denied continue, configured Calendar vs absent, dynamic folders/Steam, scope change, explicit deferral/completion no nag, cancellation/duplicate starts/late callbacks.
- [ ] Derive needs from native requiredPermission plus actual companion features (Nearby/SSID display/remote controls). No microphone/camera/InputMonitoring/FullDisk/Mac notification-center request. Use thin CoreBluetooth/CoreLocation/EventKit/AX drivers; no live grants in tests.
- [ ] Build simple welcome→automatic requests→summary/finish sheet. System Settings recovery where macOS can't re-prompt. Persist completed scope/skips; requestSteam provided callback/result persisted, read via steamConsent; callbacks injected so no dependency on C. No trigger engine.
- [ ] Exact shared API, dependency-injected drivers/storage for fake tests; foreground root controls presentation/startup. Compile/full Swift tests, signed commit/report.

### Task 4: Root integration and owner delivery
- [ ] Review independent task changes, integrate; use shared APIs. Worker builds inputs/factory and projects all rules; wrap folder/Steam evidence in consent envelope. Keep history/crypto/bounds unchanged.
- [ ] Wire setup automatically on explicit foreground after managed startup handoff settles (or explicit manual fallback), never hidden startup. Replace scattered manual folder/Wi-Fi buttons with Review setup and sheet. Finish arms new QR only after setup; paired owner no QR. BLE must not instantiate on background first-use privacy state. Native restart/handoff/cancel no double prompt.
- [ ] Add integration/wiring fake tests and complete coverage/permission matrix docs. Full Swift and upstream checks; focused Android compatibility if DTO unchanged. Fresh whole-change review.
- [ ] Mac0.5.4/build16 and Calendar/folder usage purpose keys, strict verify/self-check; Android0.5.2 unchanged. In-place install, verify pairing/status, owner chooses actual system grants and explicit phoneCheck. No publishing.

### Task 6: Permission status recovery after System Settings
- [ ] Implement the user runtime correction described in task-6-permission-refresh.md in the plan workspace: guarded automatic metadata refresh, explicit Recheck, conditional restart guidance, bounded canonical companion relaunch and exact-scope summary checkpoint.
- [ ] Fake regressions for status changes without requests/probes, lifecycle guards, explicit local validation, checkpoint identity/scope and restart sequence/failures. No owner apps, grants or power operations.
- [ ] Scoped review, integrated full suite and107vendor verification; Mac0.5.5/17 build/selfcheck and in-place update, Android0.5.2 unchanged. Verify owner runtime UI without granting permissions.
