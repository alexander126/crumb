// swift-tools-version: 6.0

import PackageDescription

// Runs the React Native adapter's PLCrashReporter-backed stack capture for real.
// The adapter itself builds only through CocoaPods beside React Native, so this
// package compiles that one dependency-light source file on its own. It is not
// a product: nothing here is published or installed by a consumer.
let package = Package(
    name: "CrumbReactNativeIOSTests",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15)
    ],
    dependencies: [
        .package(name: "crumb", path: "../../.."),
        .package(url: "https://github.com/microsoft/plcrashreporter.git", exact: "1.12.0")
    ],
    targets: [
        .target(
            name: "CrumbNativeStackCapture",
            dependencies: [
                .product(name: "CrumbCore", package: "crumb"),
                .product(name: "CrashReporter", package: "plcrashreporter")
            ],
            // A symbolic link to ../ios/CrumbNativeStackCapture.swift: SwiftPM rejects a
            // target path outside the package root, and the adapter's other sources
            // need React Native to compile.
            path: "Sources/CrumbNativeStackCapture"
        ),
        .testTarget(
            name: "CrumbNativeStackCaptureTests",
            dependencies: ["CrumbNativeStackCapture"],
            path: "Tests/CrumbNativeStackCaptureTests"
        )
    ]
)
