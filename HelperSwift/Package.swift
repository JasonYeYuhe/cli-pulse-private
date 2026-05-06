// swift-tools-version: 5.9
//
// Phase 4D: Swift port of the cli_pulse_helper daemon.
//
// Replaces the PyInstaller-frozen Python helper that Phase 4C ships
// in `Contents/Helpers/cli_pulse_helper`. Same UDS protocol, same
// `~/.claude/settings.json` semantics, same Supabase RPC surface —
// the macOS app + iPhone app + paired-device Supabase contract all
// stay backward-compatible. The win is:
//
//   * No bundled Python interpreter (~12 MB → ~3 MB binary)
//   * No PyInstaller signing edge cases (allow-jit etc.)
//   * One language stack across the whole macOS surface; reviewer
//     fatigue from Python+Swift concurrency models drops
//   * Faster startup; Swift binaries cold-start in ~30 ms vs
//     PyInstaller's ~400 ms
//
// Layout:
//   - HelperKit (library): protocol, registry, broker, PTY,
//     Supabase RPC, redaction, settings.json install.
//   - cli_pulse_helper (executable): thin main.swift wrapping
//     HelperKit's `daemon` / `pair` / `heartbeat` / `sync` /
//     `inspect` / `remote-approval-hook` / `remote-approvals`
//     subcommands. Same CLI surface as the Python version so the
//     LaunchAgent plist and dev-time invocations don't change.
//   - HelperKitTests: XCTest port of the Python pytest suite.
//     Aim is parity, not 1:1 file structure — the Swift module
//     boundaries are different, so tests group differently.

import PackageDescription

let package = Package(
    name: "HelperSwift",
    platforms: [
        // Helper runs unsandboxed via launchd; can target the
        // newest stable macOS without breaking App Store reach
        // (the SANDBOXED app's deployment target stays the
        // CLIPulseCore-declared minimum).
        .macOS(.v13),
    ],
    products: [
        .library(name: "HelperKit", targets: ["HelperKit"]),
        .executable(name: "cli_pulse_helper", targets: ["cli_pulse_helper"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "HelperKit",
            dependencies: []
        ),
        .executableTarget(
            name: "cli_pulse_helper",
            dependencies: ["HelperKit"]
        ),
        .testTarget(
            name: "HelperKitTests",
            dependencies: ["HelperKit"]
        ),
    ]
)
