// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sweevi",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "Sweevi",
            path: "Sources/Sweevi"
        )
    ]
)
