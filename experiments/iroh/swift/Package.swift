// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeepressoIrohTrial",
    platforms: [.macOS("14.5")],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi", exact: "1.2.0"),
        .package(path: "../../../macos")
    ],
    targets: [.executableTarget(name: "IrohTrial", dependencies: [
        .product(name: "IrohLib", package: "iroh-ffi"),
        .product(name: "CompanionCore", package: "macos")
    ])]
)
