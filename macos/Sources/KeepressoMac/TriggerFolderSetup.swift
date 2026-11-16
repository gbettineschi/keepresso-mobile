import AppKit
import CryptoKit
import CompanionCore
import KeepressoCore

/// Hash our own executable once. Re-signing/rebuilding changes the identity,
/// even if someone reuses the displayed app version or bundle build number.
/// This never reads a configured download folder or queries TCC databases.
enum TriggerFolderBuildIdentity {
    static let current: String = {
        guard let executable = Bundle.main.executableURL,
              let identifier = Bundle.main.bundleIdentifier,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let bytes = try? Data(contentsOf: executable) else { return "" }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "\(identifier)|\(version)|\(build)|\(digest)"
    }()
}

@MainActor final class TriggerFolderSetup: ObservableObject {
    private static let consentKey = "triggerFolderLocalConsentV1"
    @Published private(set) var status = "Download folder access has not been set up for this build."
    @Published private(set) var folders: [URL] = []
    @Published private(set) var canRequestAccess = false
    @Published private(set) var accessActionTitle = "Allow access…"
    @Published private(set) var requesting = false
    private var lastRequestFailed = false
    private var policy = TriggerFolderAccess(configuredFolders: [], buildIdentity: "")

    init() { refreshConfiguration() }

    /// Settings/markers only. Safe on launch and before a remote check: no
    /// folder enumeration, metadata probe, engine or power adapter is created.
    func refreshConfiguration() {
        guard let defaults = UserDefaults(suiteName: "sh.gyorgy.keepresso"),
              let data = defaults.data(forKey: UserDefaultsSettingsStore.defaultKey),
              let settings = try? CompanionObserverSettings.decode(data) else {
            policy = TriggerFolderAccess(configuredFolders: [], buildIdentity: "")
            folders = []; canRequestAccess = false
            status = "Saved trigger folders are unavailable. Check the rules in Keepresso, then reopen these settings."
            return
        }
        let configured = settings.ruleSet.rules.compactMap { rule -> URL? in
            if case .downloadInFolder(let folder) = rule { return folder }
            return nil
        }
        policy = TriggerFolderAccess(configuredFolders: configured, buildIdentity: TriggerFolderBuildIdentity.current,
                                     consentData: UserDefaults.standard.data(forKey: Self.consentKey))
        folders = policy.configuredFolders
        updateStatus()
    }

    /// Only foreground Mac button actions enter this method. An unsuccessful
    /// local listing cannot create a consent marker or enable the worker read.
    func allowAccess() async { await performSetup() }

    func preparePairing(arm: @escaping () -> Void) async { await performSetup(arm: arm) }

    private func performSetup(arm: (() -> Void)? = nil) async {
        guard !requesting else { return }
        refreshConfiguration()
        // Revalidation cannot reuse evidence from before a revoked/cancelled
        // local privacy choice. Persist empty evidence before the first await.
        policy = TriggerFolderAccess(configuredFolders: policy.configuredFolders, buildIdentity: TriggerFolderBuildIdentity.current)
        saveAndUpdate()
        let startingPolicy = policy
        requesting = true
        status = "Waiting for local folder access…"
        defer { requesting = false }
        NSApp.activate(ignoringOtherApps: true)
        await startingPolicy.prepare(probe: Self.probe) { result in
            // Saved rules may change while macOS waits for the owner's choice.
            // Revalidate the completed evidence before saving or exposing a QR.
            self.refreshConfiguration()
            if self.policy.configurationValid {
                self.policy = TriggerFolderAccess(configuredFolders: self.policy.configuredFolders,
                    buildIdentity: TriggerFolderBuildIdentity.current, consentData: result.consentData)
            }
            self.lastRequestFailed = !self.policy.allConfiguredApproved
            self.saveAndUpdate()
            arm?()
        }
    }

    var allConfiguredApproved:Bool {
        guard !requesting else{return false}
        refreshConfiguration()
        return policy.allConfiguredApproved
    }

    func workerConsent() -> Data? {
        // Never hand off an older grant while local revalidation is pending.
        guard !requesting else { return nil }
        refreshConfiguration()
        return policy.approvedFolders.isEmpty ? nil : policy.consentData
    }

    func openFilesAndFolders() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func probe(_ folder: URL) async -> Bool {
        // A TCC prompt can wait indefinitely for the owner. Keep that blocking
        // filesystem call off MainActor so paired telemetry/heartbeats continue.
        guard !Task.isCancelled else{return false}
        let result = await Task.detached(priority: .userInitiated) {
            // Like FileManagerDownloadScanner, inspect names/modification
            // metadata only; never open downloaded file contents.
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) != nil
        }.value
        return !Task.isCancelled && result
    }
    private func saveAndUpdate() {
        if let marker = policy.consentData { UserDefaults.standard.set(marker, forKey: Self.consentKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.consentKey) }
        updateStatus(afterRequest: true)
    }
    private func updateStatus(afterRequest: Bool = false) {
        canRequestAccess = policy.canRequestAccess
        accessActionTitle = policy.allConfiguredApproved ? "Check access…" : "Allow access…"
        if !policy.configurationValid {
            status = "Folder setup is unavailable for this build or configuration. Folder checks remain unknown."
        } else if folders.isEmpty {
            status = "No download folders are configured in Keepresso."
        } else if policy.allConfiguredApproved {
            status = "Local setup is complete for these folders and this build."
        } else if afterRequest || lastRequestFailed {
            status = "Some folders could not be read. Allow Keepresso Mobile in macOS Privacy & Security → Files and Folders, then try again. Pairing and other checks still work."
        } else {
            status = "Allow access locally before checking downloads from your phone. Unapproved folder checks remain unknown."
        }
    }
}
