// swift-tools-version:6.3
import Foundation
import PackageDescription

// With only the Command Line Tools installed, SwiftPM sometimes omits the swift-testing
// macro plugin path when compiling tests ("plugin for module 'TestingMacros' not found").
// Passing it explicitly makes test builds deterministic.
let commandLineToolsTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: commandLineToolsTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", commandLineToolsTestingPlugins])]
    : []

let package = Package(
    name: "Louder",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "LouderCore"),
        .executableTarget(name: "Louder", dependencies: ["LouderCore"]),
        .testTarget(name: "LouderCoreTests", dependencies: ["LouderCore"], swiftSettings: testSwiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
