// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FreedomPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FreedomPlayer",
            path: "Sources/FreedomPlayer"
        ),
        .testTarget(
            name: "FreedomPlayerTests",
            dependencies: ["FreedomPlayer"],
            path: "Tests/FreedomPlayerTests"
        )
    ]
)
