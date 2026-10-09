// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AIMonitorCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "aimonitor",
            dependencies: ["AIMonitorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "aimonitor-probe",
            dependencies: ["AIMonitorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "aimonitor-app",
            dependencies: ["AIMonitorCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AIMonitorCoreTests",
            dependencies: ["AIMonitorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
