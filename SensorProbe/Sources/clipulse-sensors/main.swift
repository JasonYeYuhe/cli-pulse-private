import Foundation
import SensorKit

// clipulse-sensors — emit ONE JSON object of native Apple-Silicon sensors
// (temps / fans / power) and exit. The CLI Pulse helper invokes this with a
// short timeout and merges the JSON into its heartbeat metrics + UDS snapshot.
//
// Usage: clipulse-sensors [--sample-ms N]   (default N = 300; IOReport delta window)

var sampleMs: UInt32 = 300
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    if argv[i] == "--sample-ms", i + 1 < argv.count, let n = UInt32(argv[i + 1]), n >= 50, n <= 5000 {
        sampleMs = n
        i += 2
    } else {
        i += 1
    }
}

print(SensorReader.json(sampleMs: sampleMs))
