// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuantJobs",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuantJobs",
            path: "Sources/QuantJobs",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
