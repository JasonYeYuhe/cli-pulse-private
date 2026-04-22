// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CLIPulseCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "CLIPulseCore",
            targets: ["CLIPulseCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0")
    ],
    targets: [
        .target(
            name: "CLIPulseCore",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CLIPulseCoreTests",
            dependencies: ["CLIPulseCore"]
        ),
    ]
)
