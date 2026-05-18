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
        // CodexBar-parity G1: SweetCookieKit (MIT, steipete) is NOT an SPM
        // dependency — its Package.swift requires swift-tools 6.2 while CI
        // runs Swift 6.1, which would block clean resolution. The source is
        // vendored under Sources/CLIPulseCore/Vendor/SweetCookieKit/ (each
        // file `#if os(macOS)`-wrapped). sqlite3 is linked on macOS below.
    ],
    targets: [
        .target(
            name: "CLIPulseCore",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // Required by the vendored SweetCookieKit cookie-DB reader
                // (macOS only — guarded by `#if os(macOS)` in source).
                .linkedLibrary("sqlite3", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "CLIPulseCoreTests",
            dependencies: ["CLIPulseCore"]
        ),
    ]
)
