// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "YealinkMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YMCSKit", targets: ["YMCSKit"]),
        .executable(name: "YealinkMonitor", targets: ["YealinkMonitor"]),
    ],
    targets: [
        .target(name: "YMCSKit"),
        .executableTarget(
            name: "YealinkMonitor",
            dependencies: ["YMCSKit"]
        ),
        .testTarget(
            name: "YMCSKitTests",
            dependencies: ["YMCSKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
