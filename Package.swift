// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Visualizer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Visualizer",
            path: "Sources/Visualizer"
        )
    ]
)
