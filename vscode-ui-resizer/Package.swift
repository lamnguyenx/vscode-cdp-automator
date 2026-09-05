// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "vscode-ui-resizer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "vscode-ui-resizer",
            dependencies: ["Yams"],
            path: ".",
            exclude: ["Package.swift", "vscode-ui-resizer.exe", "monitor-rules.yaml"],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-actor-data-race-checks"])
            ]
        )
    ]
)
