import Foundation

/// The JSON the `clipulse-sensors` binary emits and the Python helper merges
/// into the heartbeat `p_metrics` blob + the local machine snapshot. Only the
/// NATIVE sensors live here (temps / fans / power); battery + thermal_state come
/// from the Python side (ioreg / pmset). A nil field means "not readable on this
/// device" — the capability map tells the phone/UI what is real.
public struct SensorSnapshot: Codable {
    public var cpu_power_w: Double?
    public var gpu_power_w: Double?
    public var ane_power_w: Double?
    public var system_power_w: Double?
    public var cpu_temp_c: Double?
    public var gpu_temp_c: Double?
    public var fan_rpm: Int?
    public var fan_max_rpm: Int?
    public var capability: [String: Bool]

    public init() { capability = ["temps": false, "fans": false, "power": false] }
}

/// Pure aggregation helpers — unit-tested without hardware.
public enum SensorMath {
    /// Physical validity band for a die temperature (°C). Below the floor is a
    /// power-gated-rail artifact; above the ceiling is a bad read.
    public static let dieTempFloorC = 20.0
    public static let dieTempCeilC = 115.0

    /// SMC temp keys we treat as CPU (P-core / E-core / core) vs GPU.
    public static func isCPUTempKey(_ k: String) -> Bool {
        k.hasPrefix("Tp") || k.hasPrefix("Te") || k.hasPrefix("Tc")
    }
    public static func isGPUTempKey(_ k: String) -> Bool { k.hasPrefix("Tg") }

    /// Generous candidate SMC die-temp keys to DIRECT-READ. AppleSMC index
    /// enumeration (#KEY / read-by-index) returns nothing on many machines/OS
    /// builds even though the keys read fine by name, so we scan a broad
    /// T{p,e,g,c}{0,1}{0-9,A-F} space (matches Tp01/Tp09/Tp0D/Tg05/Tg0D on
    /// M1/M2/M3/M4). Non-existent keys simply read nil — no per-chip hardcoding.
    public static func candidateTempKeys() -> [String] {
        let clusters = ["Tp", "Te", "Tg", "Tc"]
        let hi = ["0", "1"]
        let lo = Array("0123456789ABCDEF").map(String.init)
        var out: [String] = []
        for c in clusters { for h in hi { for l in lo { out.append("\(c)\(h)\(l)") } } }
        return out
    }

    /// Average of physically-plausible readings (0 < t < 130 °C), rounded to 0.1.
    public static func averageTemp(_ values: [Double]) -> Double? {
        let valid = values.filter { $0 > 0 && $0 < 130 }
        guard !valid.isEmpty else { return nil }
        return (valid.reduce(0, +) / Double(valid.count) * 10).rounded() / 10
    }

    /// cpu/gpu die temp from the SMC temp map (key -> °C), HID as fallback.
    public static func cpuTemp(smc: [String: Double], hid: [Double]) -> Double? {
        let cpu = smc.filter { isCPUTempKey($0.key) }.map(\.value)
        if let t = averageTemp(cpu) { return t }
        return averageTemp(hid)   // coarse HID fallback
    }
    public static func gpuTemp(smc: [String: Double]) -> Double? {
        averageTemp(smc.filter { isGPUTempKey($0.key) }.map(\.value))
    }

    /// Map IOReport Energy-Model channels (name -> W) to the rails we report.
    /// `system_power_w` = sum of the top-level SoC rails present.
    public static func power(from ch: [String: Double]) -> (cpu: Double?, gpu: Double?, ane: Double?, system: Double?) {
        func pick(_ names: [String]) -> Double? {
            for n in names { if let v = ch[n] { return (v * 1000).rounded() / 1000 } }
            return nil
        }
        let cpu = pick(["CPU Energy", "CPU Energy0"])
        let gpu = pick(["GPU Energy", "GPU Energy0"])
        let ane = pick(["ANE", "ANE0"])
        let dram = pick(["DRAM", "DRAM0"])
        let parts = [cpu, gpu, ane, dram].compactMap { $0 }
        let system = parts.isEmpty ? nil : (parts.reduce(0, +) * 1000).rounded() / 1000
        return (cpu, gpu, ane, system)
    }
}

/// Reads all native sensors into a snapshot. Fail-soft: any missing subsystem
/// just leaves its fields nil + its capability flag false.
public enum SensorReader {
    public static func read(sampleMs: UInt32 = 300) -> SensorSnapshot {
        var snap = SensorSnapshot()
        let smc = SMC()

        // ── Power (IOReport Energy Model, delta-sampled) ──
        let channels = IOReportPower.sample(sampleMs: sampleMs)
        if !channels.isEmpty {
            let p = SensorMath.power(from: channels)
            snap.cpu_power_w = p.cpu
            snap.gpu_power_w = p.gpu
            snap.ane_power_w = p.ane
            snap.system_power_w = p.system
            snap.capability["power"] = (p.cpu != nil || p.system != nil)
        }

        // ── Temps (SMC Tp*/Tg* primary, HID fallback) ──
        // Direct-read the candidate set UNION any keys index-enumeration returns
        // (enumeration is empty on many machines but readable-by-name works).
        var smcTemps: [String: Double] = [:]
        if let smc = smc, smc.isOpen {
            let keys = Set(SensorMath.candidateTempKeys()).union(smc.allKeys().filter { $0.hasPrefix("T") })
            for key in keys {
                // Physical die-temp band: a running CPU/GPU die is never below
                // ~20 °C in a warm room. A power-gated GPU rail intermittently
                // reports a non-physical ~9 °C artifact; band-rejecting it keeps
                // the average honest (correct value, or nil that cycle) instead
                // of dragging gpu_temp down to garbage.
                if let v = smc.readDouble(key), v >= SensorMath.dieTempFloorC, v <= SensorMath.dieTempCeilC {
                    smcTemps[key] = v
                }
            }
        }
        let hid = HIDTemps.read().map(\.celsius)
        snap.cpu_temp_c = SensorMath.cpuTemp(smc: smcTemps, hid: hid)
        snap.gpu_temp_c = SensorMath.gpuTemp(smc: smcTemps)
        snap.capability["temps"] = (snap.cpu_temp_c != nil || snap.gpu_temp_c != nil)

        // ── Fans (SMC F{n}Ac / F{n}Mx) ──
        if let smc = smc, smc.isOpen, let n = smc.readInt("FNum"), n > 0, n < 16 {
            var actual: [Int] = []
            var maxima: [Int] = []
            for i in 0..<n {
                if let a = smc.readDouble("F\(i)Ac"), a >= 0 { actual.append(Int(a.rounded())) }
                if let m = smc.readDouble("F\(i)Mx"), m > 0 { maxima.append(Int(m.rounded())) }
            }
            if let a = actual.max() { snap.fan_rpm = a }
            if let m = maxima.max() { snap.fan_max_rpm = m }
            snap.capability["fans"] = !actual.isEmpty
        }

        return snap
    }

    public static func json(sampleMs: UInt32 = 300) -> String {
        let snap = read(sampleMs: sampleMs)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(snap), let s = String(data: data, encoding: .utf8) else {
            return "{\"capability\":{\"temps\":false,\"fans\":false,\"power\":false}}"
        }
        return s
    }
}
