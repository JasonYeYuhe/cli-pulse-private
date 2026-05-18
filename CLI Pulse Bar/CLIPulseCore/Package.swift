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
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0"),
        // CodexBar-parity G1: browser-cookie auto-import. SweetCookieKit
        // (MIT, steipete) declares only `.macOS` + links sqlite3, so it is
        // linked into the CLIPulseCore target ONLY on macOS via the
        // `.when(platforms: [.macOS])` condition below. iOS/watchOS builds
        // never resolve or link it; all SCK call sites are additionally
        // guarded with `#if os(macOS) && canImport(SweetCookieKit)`.
        .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.4.1")
    ],
    targets: [
        .target(
            name: "CLIPulseCore",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(
                    name: "SweetCookieKit",
                    package: "SweetCookieKit",
                    condition: .when(platforms: [.macOS])
                )
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
