import Foundation
import IOKit
import RootHelperCore

/// The real AppleSMC adapter — the ONLY code in the whole feature that writes SMC
/// keys. It writes EXCLUSIVELY `F{n}Md` (mode) and `F{n}Tg` (target); there is no
/// arbitrary-key write path. The read/decode and the 80-byte struct ABI are the
/// ones verified on the owner's Mac in the M0 spike (`spike/m0_fan_feasibility.
/// swift`), and the write sequence is the one M0 proved this SoC accepts:
/// `F{n}Md=1` + `F{n}Tg=rpm` (no `Ftst` needed).
///
/// Conforms to `FanSMC` so `FanController` (the safety logic) is hardware-agnostic
/// and unit-tested against a fake.
final class RealSMC: FanSMC {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    // MARK: SMC struct (80-byte beltex layout — padded to match the C ABI)

    private struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var mem: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var p0: UInt8 = 0; var p1: UInt8 = 0; var p2: UInt8 = 0 }
    private typealias B32 = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)
    private struct KeyData {
        var key: UInt32 = 0; var vers = Version(); var pLimit = PLimit(); var keyInfo = KeyInfo()
        var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0; var pad: UInt8 = 0; var data32: UInt32 = 0
        var bytes: B32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdReadKeyInfo: UInt8 = 9

    private static func fourCC(_ s: String) -> UInt32 {
        var k: UInt32 = 0; for b in s.utf8.prefix(4) { k = (k << 8) | UInt32(b) }; return k
    }
    private static func typeString(_ t: UInt32) -> String {
        let b = [UInt8((t >> 24) & 0xff), UInt8((t >> 16) & 0xff), UInt8((t >> 8) & 0xff), UInt8(t & 0xff)]
        return (String(bytes: b, encoding: .ascii) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        guard conn != 0 else { return nil }
        var out = KeyData(); var outSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &out, &outSize) == kIOReturnSuccess ? out : nil
    }

    private func keyInfo(_ key: String) -> (type: String, size: Int, rawType: UInt32)? {
        var q = KeyData(); q.key = Self.fourCC(key); q.data8 = Self.cmdReadKeyInfo
        guard let r = call(&q), r.keyInfo.dataSize > 0, r.keyInfo.dataSize <= 32 else { return nil }
        return (Self.typeString(r.keyInfo.dataType), Int(r.keyInfo.dataSize), r.keyInfo.dataType)
    }

    private func readDouble(_ key: String) -> Double? {
        guard let ki = keyInfo(key) else { return nil }
        var rd = KeyData(); rd.key = Self.fourCC(key); rd.keyInfo.dataSize = UInt32(ki.size); rd.data8 = Self.cmdReadBytes
        guard let out = call(&rd) else { return nil }
        var b = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: out.bytes) { raw in for i in 0..<32 { b[i] = raw[i] } }
        switch ki.type {
        case "flt":
            guard ki.size >= 4 else { return nil }
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let f = Float(bitPattern: bits); return f.isFinite ? Double(f) : nil
        case "ui8":  return Double(b[0])
        case "ui16": return Double(UInt16(b[0]) | (UInt16(b[1]) << 8))
        default:     return nil
        }
    }

    /// Guarded write of ONE fan key (F{n}Md / F{n}Tg only — the caller passes the
    /// pre-encoded key; there is no arbitrary-key surface). Encodes to the key's
    /// declared type (flt for Tg, ui8 for Md).
    @discardableResult
    private func writeKey(_ key: String, value: Double) -> Bool {
        // Refuse anything that is not a fan mode/target key — defence in depth so
        // a future caller bug can't turn this into an arbitrary SMC writer.
        guard key.range(of: #"^F\d+(Md|Tg)$"#, options: .regularExpression) != nil else { return false }
        guard let ki = keyInfo(key) else { return false }
        var payload = [UInt8](repeating: 0, count: ki.size)
        switch ki.type {
        case "flt":
            let bits = Float(value).bitPattern
            payload[0] = UInt8(bits & 0xff); if ki.size > 1 { payload[1] = UInt8((bits >> 8) & 0xff) }
            if ki.size > 2 { payload[2] = UInt8((bits >> 16) & 0xff) }; if ki.size > 3 { payload[3] = UInt8((bits >> 24) & 0xff) }
        case "ui8":  payload[0] = UInt8(clamping: Int(value.rounded()))
        default: return false
        }
        var wr = KeyData(); wr.key = Self.fourCC(key); wr.data8 = Self.cmdWriteBytes
        wr.keyInfo.dataSize = UInt32(ki.size); wr.keyInfo.dataType = ki.rawType
        withUnsafeMutableBytes(of: &wr.bytes) { raw in for i in 0..<min(payload.count, 32) { raw[i] = payload[i] } }
        return call(&wr) != nil
    }

    // MARK: FanSMC

    func fanCount() -> Int {
        if let n = readDouble("FNum"), n > 0, n < 10 { return Int(n) }
        var n = 0; while n < 10, keyInfo("F\(n)Ac") != nil { n += 1 }; return n
    }

    func readFan(_ i: Int) -> FanState? {
        guard let mn = readDouble("F\(i)Mn"), let mx = readDouble("F\(i)Mx") else { return nil }
        return FanState(index: i, minRPM: mn, maxRPM: mx,
                        actualRPM: readDouble("F\(i)Ac") ?? 0,
                        targetRPM: readDouble("F\(i)Tg") ?? 0,
                        mode: Int(readDouble("F\(i)Md") ?? 0))
    }

    func writeManualMode(_ i: Int, manual: Bool) -> Bool { writeKey("F\(i)Md", value: manual ? 1 : 0) }
    func writeTargetRPM(_ i: Int, rpm: Double) -> Bool { writeKey("F\(i)Tg", value: rpm) }
}
