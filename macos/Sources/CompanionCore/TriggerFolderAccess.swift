import Foundation

/// Local setup evidence, never a claim about the OS's current TCC permission.
/// URL normalization is lexical: checking a marker never touches the folder.
public struct TriggerFolderAccess {
    public static let maximumConsentBytes = 32_768
    private struct Consent: Codable {
        let buildIdentity: String
        let folders: [String]
    }
    public let configuredFolders: [URL]
    public let configurationValid: Bool
    private let buildIdentity: String
    private var approved: Set<String> = []

    public init(configuredFolders: [URL], buildIdentity: String, consentData: Data? = nil) {
        self.buildIdentity = buildIdentity
        let canonical = configuredFolders.compactMap(Self.canonicalFolder)
        configurationValid = !buildIdentity.isEmpty && buildIdentity.utf8.count <= 512
            && configuredFolders.count <= 32 && canonical.count == configuredFolders.count
        self.configuredFolders = configurationValid
            ? Array(Set(canonical)).sorted().compactMap(URL.init(string:)) : []
        guard configurationValid, let consentData, consentData.count <= Self.maximumConsentBytes,
              let consent = try? JSONDecoder().decode(Consent.self, from: consentData),
              consent.buildIdentity == buildIdentity, consent.folders.count <= 32,
              consent.folders.allSatisfy({ canonical.contains($0) }) else { return }
        approved = Set(consent.folders)
    }

    public var canRequestAccess: Bool { configurationValid && !configuredFolders.isEmpty }
    public var approvedFolders: [URL] { configuredFolders.filter(isApproved) }
    public var allConfiguredApproved: Bool { configurationValid && approvedFolders.count == configuredFolders.count }
    public var consentData: Data? {
        guard configurationValid,
              let data = try? JSONEncoder().encode(Consent(buildIdentity: buildIdentity, folders: approved.sorted())),
              data.count <= Self.maximumConsentBytes else { return nil }
        return data
    }
    public func isApproved(_ url: URL) -> Bool {
        guard let canonical = Self.canonicalFolder(url) else { return false }
        return approved.contains(canonical)
    }
    public func requestingAccess(probe: (URL) async -> Bool) async -> Self {
        var updated = self
        // Explicit revalidation never carries previous proof into its result.
        updated.approved.removeAll()
        guard configurationValid, !Task.isCancelled else { return updated }
        for folder in configuredFolders {
            guard !Task.isCancelled else { break }
            guard let canonical = Self.canonicalFolder(folder) else { continue }
            let allowed = await probe(folder)
            // A system prompt may complete after setup was cancelled. Its late
            // answer must neither authorize a read nor request the next folder.
            guard !Task.isCancelled else { break }
            if allowed { updated.approved.insert(canonical) }
        }
        if Task.isCancelled { updated.approved.removeAll() }
        return updated
    }
    /// Awaiting the owner's local privacy choice leaves the calling actor free
    /// to serve telemetry. Cancellation rejects late completion/QR callbacks.
    @MainActor public func prepare(probe: (URL) async -> Bool, complete: (Self) -> Void) async {
        guard !Task.isCancelled else { return }
        let updated = await requestingAccess(probe: probe)
        guard !Task.isCancelled else { return }
        complete(updated)
    }
    private static func canonicalFolder(_ url: URL) -> String? {
        guard url.isFileURL, url.baseURL == nil, url.host?.isEmpty != false,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              !url.path.contains("\0"), url.absoluteString.utf8.count <= 4096 else { return nil }
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true).absoluteString
    }
}
