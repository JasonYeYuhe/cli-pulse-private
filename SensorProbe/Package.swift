// swift-tools-version: 5.9
//
// System Monitor slice S3 — native Apple-Silicon sensor reader.
//
// A tiny, unsandboxed command-line tool (`clipulse-sensors`) the CLI Pulse
// helper invokes to read machine-health sensors that Python / the sandbox
// cannot: die temperatures, fan RPM, and CPU/GPU/ANE power draw. It emits a
// single JSON object and exits.
//
// Ported from vladkens/macmon (MIT) — the extern-C IOReport / AppleSMC /
// IOHIDEventSystemClient signatures, the SMC KeyData struct + FourCC decoders,
// and the Energy-Model energy→watts math. Root-free on Apple Silicon.
//
// The private IOReport / IOHID symbols are not in any SDK .tbd, so they are
// declared in the C shim header and resolved at RUNTIME via the linker's
// `-undefined dynamic_lookup` (they live in the dyld shared cache). AppleSMC +
// the public IOHIDEventSystemClient bits come from the IOKit framework.

import PackageDescription

let package = Package(
    name: "SensorProbe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "clipulse-sensors", targets: ["clipulse-sensors"]),
        .library(name: "SensorKit", targets: ["SensorKit"]),
    ],
    targets: [
        .target(name: "CSensorShim"),
        .target(
            name: "SensorKit",
            dependencies: ["CSensorShim"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "clipulse-sensors",
            dependencies: ["SensorKit"],
            linkerSettings: [
                // Resolve the private IOReport / IOHID symbols at runtime from
                // the dyld shared cache (they have no SDK stub to link against).
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
            ]
        ),
        .testTarget(
            name: "SensorKitTests",
            dependencies: ["SensorKit"],
            linkerSettings: [
                // The test bundle links SensorKit, which references the private
                // IOReport symbols — resolve them at runtime too.
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
            ]
        ),
    ]
)
