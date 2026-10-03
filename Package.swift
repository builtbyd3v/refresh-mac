// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Refresh",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RefreshCore"),
        .executableTarget(name: "refresh", dependencies: ["RefreshCore"]),
        .executableTarget(name: "RefreshApp", dependencies: ["RefreshCore"]),
        .testTarget(name: "RefreshCoreTests", dependencies: ["RefreshCore"]),
    ],
    // note: Swift 5 mode, CG/AppKit callbacks and private ObjC APIs fight strict concurrency for no gain in a single-threaded tool
    swiftLanguageModes: [.v5]
)
