import Foundation
import Testing
import KeepressoCore

struct CompanionSetupRequirementsTests {
    @Test func nativePermissionNeedsFollowRulesAndCompanionFeatures() {
        let minimal = CompanionSetupRequirements(rules: [.mediaInUse(.microphone), .audioPlaying], nearby: false, ssidDashboard: false, remoteControls: false)
        #expect(minimal.permissionNames.isEmpty)
        #expect(!minimal.remoteControls)
        let standard = CompanionSetupRequirements(rules: [])
        #expect(standard.permissionNames == ["bluetooth", "location"])
        let configured = CompanionSetupRequirements(rules: [.calendarEvent, .wifiSSID("fixture"), .bluetoothDevice("fixture")], nearby: false, ssidDashboard: false)
        #expect(configured.permissionNames == ["bluetooth", "location", "calendar"])
        #expect(configured.remoteControls)
    }

    @Test func configuredFoldersAndSteamAreDynamicWithoutReadingFilesystem() {
        let first = URL(fileURLWithPath: "/fixture/A", isDirectory: true)
        let requirements = CompanionSetupRequirements(rules: [.downloadInFolder(first), .downloadInFolder(first), .steamDownload])
        #expect(requirements.folders == [first])
        #expect(requirements.needsSteam)
        let removed = CompanionSetupRequirements(rules: [.calendarEvent])
        #expect(removed.folders.isEmpty)
        #expect(!removed.needsSteam)
        #expect(removed.permissionNames == ["bluetooth", "location", "calendar"])
    }
}
