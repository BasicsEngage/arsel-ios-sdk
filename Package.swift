// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Arsel",
    // macOS is here for CI and local `swift test`, not as a supported product platform.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Arsel", targets: ["Arsel"]),
        .library(name: "ArselNotificationExtension", targets: ["ArselNotificationExtension"]),
    ],
    targets: [
        .target(name: "Arsel"),
        // Standalone on purpose — linked into a Notification Service Extension, it must
        // stay tiny and must not drag the full SDK (see the target's ExtensionWire.swift).
        .target(name: "ArselNotificationExtension"),
        .testTarget(name: "ArselTests", dependencies: ["Arsel"]),
        .testTarget(name: "ArselNotificationExtensionTests", dependencies: ["ArselNotificationExtension"]),
    ]
)
