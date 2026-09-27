import SwiftUI
import PulseCore
import PulseCollectors

enum Format {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func celsius(_ value: Double) -> String { "\(Int(value.rounded()))°C" }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func health(_ level: HealthLevel) -> String {
        switch level {
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    static func thermal(_ state: ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    static func batteryState(_ b: BatteryReading) -> String {
        let state = b.isCharging ? "Charging" : (b.onACPower ? "On AC" : "On battery")
        guard let minutes = b.minutesRemaining else { return state }
        return "\(state) · \(minutes / 60)h \(minutes % 60)m"
    }
}

extension HealthLevel {
    /// Status colors used conservatively (PRD §15): only non-healthy states draw attention.
    var tint: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }
}

struct HealthBadge: View {
    let level: HealthLevel
    var label: String?

    var body: some View {
        Text(label ?? Format.health(level))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(level.tint)
            .background(level.tint.opacity(0.15), in: Capsule())
    }
}
