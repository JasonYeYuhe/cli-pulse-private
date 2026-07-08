// MachineFormat.swift — shared read-only formatters for machine-health metrics.
// Used by iOSMachineView (v1.41); mirrors the private helpers in the macOS
// MachineHealthView so the two surfaces format uptime / bytes / pressure the same.

import SwiftUI

public enum MachineFormat {
    /// "3d 4h" / "4h 12m" / "12m".
    public static func uptime(_ seconds: Int) -> String {
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Whole-GB string, matching the macOS Machine tab.
    public static func gb(_ bytes: Int) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824.0)
    }

    /// Localized memory-pressure label (nominal/warn/critical → Normal/Elevated/High).
    public static func memPressureLabel(_ level: String) -> String {
        switch level {
        case "warn": return L10n.machine.pressureElevated
        case "critical": return L10n.machine.pressureHigh
        default: return L10n.machine.pressureNormal
        }
    }

    public static func memPressureColor(_ level: String) -> Color {
        switch level {
        case "warn": return .orange
        case "critical": return .red
        default: return .green
        }
    }
}
