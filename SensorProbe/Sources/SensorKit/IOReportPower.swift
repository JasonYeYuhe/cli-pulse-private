import CSensorShim
import Foundation

/// IOReport "Energy Model" power reader. IOReport is a DELTA API: we take two
/// samples separated by a REAL sleep and divide the energy delta by elapsed
/// seconds (energy → watts). Ported from macmon (MIT).
public enum IOReportPower {

    /// Watts per top-level rail, e.g. ["CPU Energy": 5.25, "GPU Energy": 1.30,
    /// "ANE0": 0.0, "DRAM0": 1.28]. Empty on failure (no channels / not AS).
    public static func sample(sampleMs: UInt32) -> [String: Double] {
        guard let channelsU = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0) else { return [:] }
        let channels = channelsU.takeRetainedValue()
        var subbed: Unmanaged<CFMutableDictionary>? = nil
        guard let subU = IOReportCreateSubscription(nil, channels, &subbed, 0, nil) else { return [:] }
        let sub = subU.takeRetainedValue()
        let subChannels = subbed?.takeRetainedValue() ?? channels

        guard let s1U = IOReportCreateSamples(sub, subChannels, nil) else { return [:] }
        let s1 = s1U.takeRetainedValue()
        usleep(sampleMs * 1000)   // real sleep — the whole point of a delta API
        guard let s2U = IOReportCreateSamples(sub, subChannels, nil) else { return [:] }
        let s2 = s2U.takeRetainedValue()
        guard let deltaU = IOReportCreateSamplesDelta(s1, s2, nil) else { return [:] }
        let delta = deltaU.takeRetainedValue()

        let dt = Double(sampleMs) / 1000.0
        guard dt > 0, let items = (delta as NSDictionary)["IOReportChannels"] as? [AnyObject] else { return [:] }

        var out: [String: Double] = [:]
        for it in items {
            let ch = it as! CFDictionary
            let name = ((IOReportChannelGetChannelName(ch)?.takeUnretainedValue()) as String?) ?? ""
            let unit = (((IOReportChannelGetUnitLabel(ch)?.takeUnretainedValue()) as String?) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard let joules = joules(fromEnergy: IOReportSimpleGetIntegerValue(ch, 0), unit: unit) else { continue }
            out[name, default: 0] += joules / dt
        }
        return out
    }

    /// Convert a raw IOReport energy counter to joules using its unit label.
    /// Pure; unit-tested. Returns nil for a non-energy unit (skip that channel).
    public static func joules(fromEnergy raw: Int64, unit: String) -> Double? {
        switch unit {
        case "mJ": return Double(raw) / 1_000.0
        case "uJ": return Double(raw) / 1_000_000.0
        case "nJ": return Double(raw) / 1_000_000_000.0
        default:   return nil
        }
    }
}
