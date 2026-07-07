// swift-tools-version:5.9
//
// M2 — Machine root privileged-helper (SKELETON / DRAFT — NOT shipped).
// =============================================================================
// This is the "hard security infrastructure" milestone (M2) from
// DEV_PLAN_2026-07-06_machine_controls.md: a compiled root daemon that will
// eventually let the Machine tab do privileged things (M3 fan control; M4
// root/other-user kill). It ships NOTHING user-facing and is deliberately a
// SEPARATE SwiftPM package NOT referenced by the app's Xcode project — it can
// only run if the owner explicitly installs it. It stays build-flag / package
// gated until M3.
//
// M2 exposes ONLY introspection (ping / capabilities). No fan write. No kill.
// Its entire job is to get the ROOT IPC AUTHENTICATION right — XPC + per-message
// audit_token → SecCode → Team-ID/designated-requirement — so the dangerous
// commands (M3/M4) can be added later on top of a reviewed foundation.
//
// The install/launch MECHANISM is deliberately deferred (owner decision, pending
// the M0 go/no-go): SMAppService.daemon (recommended) vs a system-domain root
// .pkg LaunchDaemon. Nothing here hard-codes the choice — main.swift binds a
// Mach service name that either mechanism can register.
import PackageDescription

let package = Package(
    name: "MachineRootHelper",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, testable core: the security decision logic + dead-man's-switch +
        // command guards + the XPC protocol. No privileged side effects here.
        .target(name: "RootHelperCore"),
        // The root daemon entry point. Wires NSXPCListener to the core's peer
        // authenticator. This is the only target that touches XPC / audit tokens.
        .executableTarget(name: "machine-root-helper", dependencies: ["RootHelperCore"]),
        .testTarget(name: "RootHelperCoreTests", dependencies: ["RootHelperCore"]),
    ]
)
