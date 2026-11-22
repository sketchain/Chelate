// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "PVEKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "PVEKit", targets: ["PVEKit"]),
    ],
    targets: [
        .target(
            name: "PVEKit",
            path: "Sources/PVEKit"
        ),
        .testTarget(
            name: "PVEKitTests",
            dependencies: ["PVEKit"],
            path: "Tests/PVEKitTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
