// swift-tools-version:6.0
import Foundation
import PackageDescription

// swift-testing ships inside Command Line Tools at paths SwiftPM doesn't wire
// up itself: the macro plugin isn't on the plugin search path, and
// Testing.framework isn't on the test bundle's rpath. Adding them
// unconditionally would break machines that have full Xcode (where the paths
// don't exist and the toolchain finds swift-testing on its own), so the manifest
// checks before opting in.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let cltInterop = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let needsCLTTestPaths = FileManager.default.fileExists(atPath: cltFrameworks)
    && FileManager.default.fileExists(atPath: cltPlugins)

let testSwiftSettings: [SwiftSetting] = needsCLTTestPaths
    ? [.unsafeFlags(["-plugin-path", cltPlugins])]
    : []

let testLinkerSettings: [LinkerSetting] = needsCLTTestPaths
    ? [.unsafeFlags([
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltInterop,
      ])]
    : []

// No external dependencies, deliberately: dependency resolution adds startup
// latency and supply-chain surface for a daemon that must be up all the time.
let package = Package(
    name: "voxrouter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoxRouterKit", targets: ["VoxRouterKit"]),
        .executable(name: "voxrouter", targets: ["voxrouter"]),
        .executable(name: "VoxRouterApp", targets: ["VoxRouterApp"]),
    ],
    targets: [
        .target(
            name: "VoxRouterKit",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(name: "voxrouter", dependencies: ["VoxRouterKit"]),
        // Bundled into VoxRouter.app by Scripts/build-app.sh — SwiftPM alone
        // produces a bare binary, and TCC will not grant microphone access to
        // one of those.
        .executableTarget(name: "VoxRouterApp", dependencies: ["VoxRouterKit"]),
        // Uses swift-testing rather than XCTest, which isn't present without
        // full Xcode. See the CLT path detection above.
        .testTarget(
            name: "VoxRouterKitTests",
            dependencies: ["VoxRouterKit"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
