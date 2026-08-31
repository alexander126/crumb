// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Crumb",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "CrumbCore", targets: ["CrumbCore"]),
        .library(name: "CrumbUI", targets: ["CrumbUI"])
    ],
    targets: [
        .target(
            name: "CrumbCore",
            path: "packages/ios/Sources/CrumbCore"
        ),
        .target(
            name: "CrumbUI",
            dependencies: ["CrumbCore"],
            path: "packages/ios/Sources/CrumbUI",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CrumbCoreTests",
            dependencies: ["CrumbCore"],
            path: "packages/ios/Tests/CrumbCoreTests"
        ),
        .testTarget(
            name: "CrumbUITests",
            dependencies: ["CrumbUI"],
            path: "packages/ios/Tests/CrumbUITests"
        )
    ]
)
