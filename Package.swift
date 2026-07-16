// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gjPiP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "gjPiP",
            path: "Sources/gjPiP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
