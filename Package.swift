// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalMusic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LocalMusic", path: "Sources/LocalMusic")
    ]
)
