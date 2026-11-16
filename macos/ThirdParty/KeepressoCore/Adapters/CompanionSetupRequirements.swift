import Foundation

/// Metadata-only setup requirements. No monitor, filesystem probe or permission request.
public struct CompanionSetupRequirements {
    public let permissionNames: [String]
    public let folders: [URL]
    public let needsSteam: Bool
    public let remoteControls: Bool

    public init(rules: [TriggerRule], nearby: Bool = true, ssidDashboard: Bool = true, remoteControls: Bool = true) {
        var permissions = Set(rules.compactMap { $0.requiredPermission?.rawValue })
        if nearby { permissions.insert(TriggerRule.Permission.bluetooth.rawValue) }
        if ssidDashboard { permissions.insert(TriggerRule.Permission.location.rawValue) }
        // Nearby connectivity first; remaining consent follows the dashboard and rules.
        permissionNames = ["bluetooth", "location", "calendar"].filter { permissions.contains($0) }
        folders = Array(Set(rules.compactMap { rule -> URL? in
            guard case .downloadInFolder(let folder) = rule else { return nil }
            return folder.isFileURL ? folder.standardizedFileURL : folder
        })).sorted { $0.absoluteString < $1.absoluteString }
        needsSteam = rules.contains { if case .steamDownload = $0 { return true }; return false }
        self.remoteControls = remoteControls
    }
}
