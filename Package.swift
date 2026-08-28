// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "YealinkMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YMCSKit", targets: ["YMCSKit"]),
        .library(name: "SMTPKit", targets: ["SMTPKit"]),
        .executable(name: "YealinkMonitor", targets: ["YealinkMonitor"]),
    ],
    targets: [
        .target(name: "YMCSKit"),
        .target(name: "SMTPKit"),
        .executableTarget(
            name: "YealinkMonitor",
            dependencies: ["YMCSKit", "SMTPKit"]
        ),
        .testTarget(
            name: "YMCSKitTests",
            dependencies: ["YMCSKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SMTPKitTests",
            dependencies: ["SMTPKit"]
        ),
    ]
)
