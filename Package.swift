// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sweevi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sweevi",
            path: "Sources/Sweevi"
        )
    ]
)
