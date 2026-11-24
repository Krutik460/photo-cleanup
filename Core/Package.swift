// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoCleanupCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PhotoCleanupCore", targets: ["PhotoCleanupCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "PhotoCleanupCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "photocleanup-cli", dependencies: ["PhotoCleanupCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PhotoCleanupCoreTests", dependencies: ["PhotoCleanupCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
