import Foundation

/// A property wrapper for a JSON integer that may exceed the platform `Int`
/// range. The **Apple Watch is `arm64_32` — `Int` is 32-bit** (max
/// 2,147,483,647), but cloud usage/token counters can exceed 2³¹ for heavy
/// accounts. Without this, `JSONDecoder` decoding such a value into `Int`
/// throws and the *entire* `ProviderUsage` / `DashboardSummary` payload
/// fails to decode on the watch — the user just sees "Couldn't load".
///
/// This decodes into the widest fixed type (`Int64`) first and **saturates**
/// at `Int.max` / `Int.min` instead of throwing. On 64-bit platforms
/// (iPhone, Mac) `Int` is already 64-bit, so the saturation branch never
/// triggers and behaviour is identical to a plain `Int` — the display
/// already abbreviates to K/M/B, so a clamped count still reads sensibly on
/// the watch in the (rare) >2 billion case.
///
/// Transparent: the wrapped value reads as a plain `Int`, the memberwise
/// init still takes `Int`, and it re-encodes as a plain integer — so call
/// sites (collectors, views) are unchanged.
@propertyWrapper
public struct SaturatingInt: Codable, Sendable, Hashable {
    public var wrappedValue: Int

    public init(wrappedValue: Int) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Fast path: fits in the platform Int (always true on 64-bit).
        if let value = try? container.decode(Int.self) {
            wrappedValue = value
            return
        }
        // Overflowed the platform Int (only possible on 32-bit watch): decode
        // as Int64 and clamp into the platform Int range.
        let wide = try container.decode(Int64.self)
        wrappedValue = SaturatingInt.clamp(wide)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    /// Clamp an `Int64` into the platform `Int` range.
    public static func clamp(_ value: Int64) -> Int {
        if value > Int64(Int.max) { return Int.max }
        if value < Int64(Int.min) { return Int.min }
        return Int(value)
    }
}
