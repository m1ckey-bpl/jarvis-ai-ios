// swift-tools-version:5.9
// JarvisCore — the JARVIS engine. Foundation-only so that it compiles on
// Linux (testable in CI / agent sandboxes) AND inside the iOS app target.
import PackageDescription

let package = Package(
    name: "JarvisCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "JarvisCore", targets: ["JarvisCore"])],
    targets: [
        // Linux has no SQLite3 module in the Swift SDK; this system-library shim
        // supplies it. On Apple platforms `import SQLite3` is provided by the SDK.
        .systemLibrary(
            name: "CSQLite",
            path: "JarvisCore/Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "JarvisCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
            path: "JarvisCore/Sources/JarvisCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"],
            path: "JarvisTests"
        )
    ]
)
