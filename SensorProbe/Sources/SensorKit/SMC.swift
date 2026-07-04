import CSensorShim
import Foundation
import IOKit

/// Minimal AppleSMC client: opens the user client, reads keys (with dynamic
/// key-by-index enumeration so we never hardcode a per-chip temp-key map), and
/// decodes the SMC value types. Root-free; read-only. Ported from beltex/SMCKit
/// (MIT) + macmon's Apple-Silicon `flt` handling.
public final class SMC {
    private var conn: io_connect_t = 0
    public var isOpen: Bool { conn != 0 }

    // AppleSMC user-client selector + KeyData command bytes.
    private static let kSMCUserClientOpen: UInt32 = 0
    private static let kSMCHandleYPCEvent: UInt32 = 2   // IOConnectCallStructMethod selector
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadIndex: UInt8 = 8
    private static let cmdReadKeyInfo: UInt8 = 9

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, Self.kSMCUserClientOpen, &conn) == kIOReturnSuccess else {
            return nil
        }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    // MARK: - FourCC helpers (pure; unit-tested)

    public static func fourCC(_ s: String) -> UInt32 {
        var k: UInt32 = 0
        for b in s.utf8.prefix(4) { k = (k << 8) | UInt32(b) }
        return k
    }

    public static func keyString(_ k: UInt32) -> String {
        let bytes = [UInt8((k >> 24) & 0xff), UInt8((k >> 16) & 0xff), UInt8((k >> 8) & 0xff), UInt8(k & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    public static func typeString(_ t: UInt32) -> String {
        keyString(t).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }

    /// Decode raw SMC bytes of a given type. Pure; unit-tested independent of hardware.
    /// `flt` is IEEE-754 little-endian; `ui*` little-endian; `sp78`/`fpe2` big-endian fixed-point (Intel).
    public static func decode(type: String, bytes b: [UInt8]) -> Double? {
        switch type {
        case "flt":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "ui8":  return b.count >= 1 ? Double(b[0]) : nil
        case "ui16": return b.count >= 2 ? Double(UInt16(b[0]) | (UInt16(b[1]) << 8)) : nil
        case "ui32": return b.count >= 4 ? Double(UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)) : nil
        case "sp78": return b.count >= 2 ? Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1]))) / 256.0 : nil
        case "fpe2": return b.count >= 2 ? Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1])) >> 2) : nil
        default:     return nil
        }
    }

    // MARK: - kernel calls

    private func call(_ input: inout SMCKeyData_t) -> SMCKeyData_t? {
        guard conn != 0 else { return nil }
        var output = SMCKeyData_t()
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        let r = IOConnectCallStructMethod(conn, Self.kSMCHandleYPCEvent,
                                          &input, MemoryLayout<SMCKeyData_t>.stride,
                                          &output, &outSize)
        return r == kIOReturnSuccess ? output : nil
    }

    /// Read a key -> (type, bytes), or nil if the key is absent/unreadable.
    public func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        var info = SMCKeyData_t()
        info.key = Self.fourCC(key)
        info.data8 = Self.cmdReadKeyInfo
        guard let ki = call(&info), ki.keyInfo.dataSize > 0 else { return nil }
        let size = Int(ki.keyInfo.dataSize)
        // Enforce the fixed 32-byte payload buffer BEFORE the read-bytes call —
        // never hand a >32 dataSize across the kernel ABI boundary.
        guard size <= 32 else { return nil }
        let type = Self.typeString(ki.keyInfo.dataType)

        var rd = SMCKeyData_t()
        rd.key = Self.fourCC(key)
        rd.keyInfo.dataSize = ki.keyInfo.dataSize
        rd.data8 = Self.cmdReadBytes
        guard let out = call(&rd) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: out.bytes) { raw in for i in 0..<32 { bytes[i] = raw[i] } }
        return (type, Array(bytes.prefix(size)))
    }

    public func readDouble(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        return Self.decode(type: type, bytes: bytes)
    }

    public func readInt(_ key: String) -> Int? { readDouble(key).map { Int($0.rounded()) } }

    /// Enumerate ALL SMC key names via #KEY count + read-by-index. Non-hardcoded
    /// so temp/fan key discovery works across M1/M2/M3/M4.
    public func allKeys() -> [String] {
        guard let count = readInt("#KEY"), count > 0, count < 10000 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var idx = SMCKeyData_t()
            idx.data8 = Self.cmdReadIndex
            idx.data32 = UInt32(i)
            guard let out = call(&idx), out.key != 0 else { continue }
            keys.append(Self.keyString(out.key))
        }
        return keys
    }
}
