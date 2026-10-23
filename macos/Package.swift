// swift-tools-version: 5.9
import PackageDescription
import Foundation
let testingPlugin = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
#if compiler(>=6.4)
let testFlags: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugin) ? [.unsafeFlags(["-load-plugin-library", testingPlugin])] : []
#else
let testFlags: [SwiftSetting] = []
#endif
let package = Package(name: "KeepressoMac", defaultLocalization: "en", platforms: [.macOS(.v14)], products: [
    .library(name: "CompanionCore", targets: ["CompanionCore"]),
    .executable(name: "KeepressoMac", targets: ["KeepressoMac"])
], targets: [
    .target(name: "CompanionCore"),
    .target(name: "KeepressoCore", path: "ThirdParty/KeepressoCore", exclude: ["LICENSE", "Sources/de.lproj", "Sources/en.lproj", "Sources/es.lproj", "Sources/fr.lproj", "Sources/hu.lproj", "Sources/it.lproj", "Sources/ja.lproj", "Sources/ko.lproj", "Sources/pl.lproj", "Sources/pt-BR.lproj", "Sources/ru.lproj", "Sources/tr.lproj", "Sources/uk.lproj", "Sources/zh-Hans.lproj", "Sources/zh-Hant.lproj"], sources: ["Sources", "Adapters"]),
    .executableTarget(name: "KeepressoMac", dependencies: ["CompanionCore", "KeepressoCore"]),
    .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore", "KeepressoCore"], swiftSettings: testFlags)
])
