import SwiftUI
import PulseCore
import PulseCollectors

enum Format {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func celsius(_ value: Double) -> String { "\(Int(value.rounded()))°C" }

    /// Card-sized: whole units from 10 up ("575 GB", "4.5 GB").
    static func bytesShort(_ value: Int64) -> String {
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB")]
        for (scale, unit) in units where Double(value) >= scale {
            let v = Double(value) / scale
            return v >= 10 ? "\(Int(v.rounded())) \(unit)" : String(format: "%.1f %@", v, unit)
        }
        return bytes(value)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// "8.4 MB/s" (decimal units, like Activity Monitor).
    static func rate(_ bytesPerSecond: Double) -> String {
        rateFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))) + "/s"
    }

    /// Configured once, then only read; Foundation formatters are thread-safe for formatting.
    nonisolated(unsafe) private static let rateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB"
        return f
    }()

    /// "19.8 / 32 GB" — used over total in the total's unit (mockup memory value).
    static func memoryUsage(used: UInt64, total: UInt64) -> String {
        let gib = 1_073_741_824.0
        let t = Double(total) / gib, u = Double(used) / gib
        return String(format: "%.1f / %.0f GB", u, t)
    }

    static func batteryCondition(_ c: BatteryCondition) -> String {
        switch c {
        case .normal: "Normal"
        case .serviceRecommended: "Service Recommended"
        }
    }

    /// "3h 42m" for a minute count.
    static func duration(minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }

    /// "3d 12h 16m" — uptime, which is usually days rather than hours.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let (days, hours, minutes) = (total / 86_400, total % 86_400 / 3_600, total % 3_600 / 60)
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }

    /// "4.05 GHz". Frequencies are reported in hertz.
    static func frequency(_ hertz: Double) -> String {
        String(format: "%.2f GHz", hertz / 1e9)
    }

    /// "12.3 W", or milliwatts below a watt where a GPU spends most of its time.
    static func watts(_ value: Double) -> String {
        value < 1 ? String(format: "%.0f mW", value * 1_000) : String(format: "%.2f W", value)
    }

    /// Load average is a thread count, not a percentage, so it keeps two decimals.
    static func load(_ value: Double) -> String { String(format: "%.2f", value) }

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
        return "\(state) · \(duration(minutes: minutes))"
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
