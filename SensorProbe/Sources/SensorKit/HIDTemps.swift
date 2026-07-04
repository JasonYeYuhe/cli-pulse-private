import CSensorShim
import Foundation
import IOKit

/// IOHIDEventSystemClient temperature reader — the Apple-Silicon fallback when
/// SMC die-temp keys aren't populated (technique from freedomtan/sensors +
/// macmon). Matches HID services with PrimaryUsagePage 0xff00 / PrimaryUsage 5
/// and reads the kIOHIDEventTypeTemperature (15) float value.
public enum HIDTemps {
    private static let usagePage = 0xff00
    private static let usage = 0x0005
    private static let eventTypeTemperature: Int64 = 15

    /// [(sensor name, °C)]. Empty on failure.
    public static func read() -> [(name: String, celsius: Double)] {
        let matching: CFDictionary = ["PrimaryUsagePage": usagePage, "PrimaryUsage": usage] as NSDictionary
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        IOHIDEventSystemClientSetMatching(client, matching)
        guard let cfServices = IOHIDEventSystemClientCopyServices(client) else { return [] }
        let services = (cfServices as NSArray) as [AnyObject]

        var out: [(String, Double)] = []
        let field = Int32(eventTypeTemperature << 16)
        for svc in services {
            let s = svc as! IOHIDServiceClient
            let name = (IOHIDServiceClientCopyProperty(s, "Product" as CFString) as? String) ?? ""
            guard let ev = IOHIDServiceClientCopyEvent(s, eventTypeTemperature, 0, 0) else { continue }
            let t = IOHIDEventGetFloatValue(ev, field)
            // IOHIDEventRef imports as an OpaquePointer (not ARC-managed), and
            // Copy returns it +1 — balance that owning ref so repeated/in-process
            // sampling can't leak. (CFRelease is unavailable to Swift.)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ev)).release()
            if t > 0, t < 150 { out.append((name, t)) }
        }
        return out
    }
}
