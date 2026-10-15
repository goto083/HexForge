// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HexForge",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "HexForge",
            path: "Sources/HexForge"
        )
    ]
)