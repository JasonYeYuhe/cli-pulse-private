// WatchDeviceSummary.swift — v1.41 "Mobile Machine", watch side (PR-7).
//
// A TRIMMED, read-only device-health record for the watch: only the fields the
// glance card + drill-in render, so the phone→watch WatchConnectivity context
// stays small (updateApplicationContext has a ~256 KB ceiling) and the watch
// never carries the control-plane fields (machine_controls, fan target, etc. —
// the watch has no controls, by design). Codable both ways with the default
// camelCase keys (this is internal WC serialization, not the snake_case REST
// wire), so the phone encodes and the watch decodes the same type.

import Foundation

public struct WatchDeviceSummary: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: String
    public let cpuUsage: Int?
    public let memoryUsage: Int?
    public let cpuTempC: Double?
    public let fanRpm: Int?
    public let thermalState: Int?
    public let batteryChargePct: Int?
    public let batteryState: String?
    public let batteryHealthPct: Double?
    public let uptimeSeconds: Int?
    public let loadAvg1m: Double?
    public let memoryPressure: String?
    public let diskFreeBytes: Int?
    public let diskTotalBytes: Int?
    public let lpmOn: Bool?
    public let fanBoostActive: Bool?
    public let fanBoostTargetRpm: Int?
    public let sensorsUpdatedAt: String?

    public var deviceStatus: DeviceStatus? { DeviceStatus(rawValue: status) }

    /// Grey stale readings (>5 min), matching iOSMachineView.
    public func isReadingStale(after: TimeInterval = 300, now: Date = Date()) -> Bool {
        guard let ts = sharedISO8601Parse(sensorsUpdatedAt ?? "") else { return false }
        return now.timeIntervalSince(ts) > after
    }

    public init(from d: DeviceRecord) {
        id = d.id
        name = d.name
        status = d.status
        cpuUsage = d.cpu_usage
        memoryUsage = d.memory_usage
        cpuTempC = d.cpu_temp_c
        fanRpm = d.fan_rpm
        thermalState = d.thermal_state
        batteryChargePct = d.battery_charge_pct
        batteryState = d.battery_state
        batteryHealthPct = d.battery_health_pct
        uptimeSeconds = d.uptime_seconds
        loadAvg1m = d.load_avg_1m
        memoryPressure = d.memory_pressure
        diskFreeBytes = d.disk_free_bytes
        diskTotalBytes = d.disk_total_bytes
        lpmOn = d.lpm_on
        fanBoostActive = d.fan_boost_active
        fanBoostTargetRpm = d.fan_boost_target_rpm
        sensorsUpdatedAt = d.sensors_updated_at
    }

    // Memberwise init for tests / previews.
    public init(id: String, name: String, status: String,
                cpuUsage: Int? = nil, memoryUsage: Int? = nil, cpuTempC: Double? = nil,
                fanRpm: Int? = nil, thermalState: Int? = nil, batteryChargePct: Int? = nil,
                batteryState: String? = nil, batteryHealthPct: Double? = nil,
                uptimeSeconds: Int? = nil, loadAvg1m: Double? = nil, memoryPressure: String? = nil,
                diskFreeBytes: Int? = nil, diskTotalBytes: Int? = nil,
                lpmOn: Bool? = nil, fanBoostActive: Bool? = nil, fanBoostTargetRpm: Int? = nil,
                sensorsUpdatedAt: String? = nil) {
        self.id = id; self.name = name; self.status = status
        self.cpuUsage = cpuUsage; self.memoryUsage = memoryUsage; self.cpuTempC = cpuTempC
        self.fanRpm = fanRpm; self.thermalState = thermalState; self.batteryChargePct = batteryChargePct
        self.batteryState = batteryState; self.batteryHealthPct = batteryHealthPct
        self.uptimeSeconds = uptimeSeconds; self.loadAvg1m = loadAvg1m; self.memoryPressure = memoryPressure
        self.diskFreeBytes = diskFreeBytes; self.diskTotalBytes = diskTotalBytes
        self.lpmOn = lpmOn; self.fanBoostActive = fanBoostActive; self.fanBoostTargetRpm = fanBoostTargetRpm
        self.sensorsUpdatedAt = sensorsUpdatedAt
    }
}

public enum WatchDeviceTrim {
    /// Default cap on devices synced to the watch (WC context size + glance density).
    public static let watchDeviceLimit = 4

    /// Keep only devices that report machine health, cap to `limit`, preserving
    /// the caller's order (the phone lists devices last-seen-desc). Used for BOTH
    /// the WC payload the phone sends and the watch's own live `api.devices()`.
    public static func summaries(from devices: [DeviceRecord],
                                 limit: Int = watchDeviceLimit) -> [WatchDeviceSummary] {
        devices.filter { $0.hasDeviceHealth }
            .prefix(max(0, limit))
            .map(WatchDeviceSummary.init(from:))
    }
}
