import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

enum Format {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func celsius(_ value: Double) -> String { "\(Int(value.rounded()))°C" }

    /// Card-sized: whole units from 10 up ("575 GB", "4.5 GB").
    static func bytesShort(_ value: Int64) -> String {
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB")]
        for (scale, unit) in units where Double(value) >= scale {
            let v = Double(value) / scale
            return v >= 10 ? "\(decimal(v, places: 0)) \(unit)" : "\(decimal(v, places: 1)) \(unit)"
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

    /// Memory in GB with a fixed number of decimals, binary like Activity Monitor ("20.3", "24").
    static func gigabytes(_ bytes: UInt64, places: Int) -> String {
        decimal(Double(bytes) / 1_073_741_824, places: places)
    }

    /// "19.8 / 32 GB" — used over total in the total's unit (mockup memory value).
    static func memoryUsage(used: UInt64, total: UInt64) -> String {
        let gib = 1_073_741_824.0
        return "\(decimal(Double(used) / gib, places: 1)) / \(decimal(Double(total) / gib, places: 0)) GB"
    }

    static func batteryCondition(_ c: BatteryCondition) -> String {
        switch c {
        case .normal: "Normal"
        case .serviceRecommended: "Service Recommended"
        }
    }

    /// "3h 42m" for a minute count.
    static func duration(minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }

    /// Decimals the user's region agrees with: `String(format:)` always writes ".", so a machine
    /// set to a comma-decimal locale would read "2.42 GHz" where the rest of macOS says "2,42 GHz".
    static func decimal(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)).grouping(.automatic))
    }

    /// "3d 12h 16m" — uptime, which is usually days rather than hours.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let (days, hours, minutes) = (total / 86_400, total % 86_400 / 3_600, total % 3_600 / 60)
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }

    /// "4.05 GHz". Frequencies are reported in hertz.
    static func frequency(_ hertz: Double) -> String {
        "\(decimal(hertz / 1e9, places: 2)) GHz"
    }

    /// "12.3 W", or milliwatts below a watt where a GPU spends most of its time.
    static func watts(_ value: Double) -> String {
        value < 1 ? "\(decimal(value * 1_000, places: 0)) mW" : "\(decimal(value, places: 2)) W"
    }

    /// Load average is a thread count, not a percentage, so it keeps two decimals.
    static func load(_ value: Double) -> String { decimal(value, places: 2) }

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

    /// The signal's name inside a sentence: "Memory pressure is Warning".
    static func concernName(_ signal: ConcernSignal) -> String {
        switch signal {
        case .cpu: "CPU"
        case .memory: "Memory pressure"
        case .internet: "Internet"
        case .battery: "Battery condition"
        case .thermal: "Thermal state"
        }
    }

    /// The Popover banner's headline for a Concern.
    static func concernTitle(_ signal: ConcernSignal, offline: Bool) -> String {
        switch signal {
        case .cpu: "CPU busy"
        case .memory: "Memory under pressure"
        case .internet: offline ? "Offline" : "Internet slow"
        case .battery: "Battery needs service"
        case .thermal: "Mac running hot"
        }
    }

    /// "CPU, thermals and network are healthy." Nil when nothing is.
    static func healthyLine(_ signals: [ConcernSignal]) -> String? {
        let names = signals.map { signal in
            switch signal {
            case .cpu: "CPU"
            case .memory: "memory"
            case .internet: "network"
            case .battery: "battery"
            case .thermal: "thermals"
            }
        }
        guard let first = names.first else { return nil }
        let list = names.formatted(.list(type: .and))
        let verb = names.count > 1 || first == "thermals" ? "are" : "is"
        return list.prefix(1).uppercased() + list.dropFirst() + " \(verb) healthy."
    }

    /// "Fans 1,900 rpm" for the fastest fan, "Fans stopped" when none spins. Nil without fans.
    static func fans(_ fans: [FanReading]) -> String? {
        guard let fastest = fans.map(\.rpm).max() else { return nil }
        return fastest < 1 ? "Fans stopped" : "Fans \(decimal(fastest, places: 0)) rpm"
    }

    /// "Updated just now" while samples arrive on schedule; the age only once one is overdue (e.g.
    /// after wake). Scaled to the sampling interval so a 5 s setting does not tick through "3s ago".
    static func freshness(_ last: Date?, now: Date, interval: TimeInterval) -> String {
        guard let last else { return "Starting…" }
        let age = now.timeIntervalSince(last)
        return age < max(3, 2 * interval) ? "Updated just now" : "Updated \(Int(age))s ago"
    }

    /// "MacBook · M5 Pro" — the kind of Mac and its chip, from what this Mac reports. The marketing
    /// model name has no public API, so it is not guessed.
    static func macSummary(hasBattery: Bool, processor: String?) -> String {
        let chip = processor.map { $0.hasPrefix("Apple ") ? String($0.dropFirst(6)) : $0 }
        return [hasBattery ? "MacBook" : "Mac", chip].compactMap { $0 }.joined(separator: " · ")
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
    /// How much of the tint the capsule fill carries. Ink is measured against this mix, not the
    /// tint: the two are the same hue, so the fill is the only thing the label contrasts with.
    static let fillOpacity = 0.15

    let level: HealthLevel
    var label: String?

    var body: some View {
        Text(label ?? Format.health(level))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(level.tint.readableInk(on: .tintedFill(Self.fillOpacity), minimum: 4.5))
            .background(level.tint.opacity(Self.fillOpacity), in: Capsule())
    }
}

/// A Health Level as glyph plus word ("✓ Healthy") under a popover row's value.
struct HealthStatus: View {
    let level: HealthLevel
    var label: String?

    var body: some View {
        HStack(spacing: 4) {
            SeverityMark(level: level, font: .caption2)
            Text(label ?? Format.health(level))
                .font(.caption)
                .foregroundStyle(level.tint.readableInk(on: .card, minimum: 4.5))
        }
        .lineLimit(1)
    }
}

extension HealthLevel {
    /// The tint as a *mark* — a dot or glyph on a card, which WCAG 1.4.11 holds to 3:1.
    var markTint: Color { tint.readableInk(on: .card, minimum: 3.0) }

    /// The shape that carries the level when colour cannot: red and green are the pair 8% of men
    /// cannot separate, and a severity dot printed at 8pt is the app's smallest colour-only signal.
    /// Shapes escalate the way the levels do — a closed circle, a triangle, then an octagon.
    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// A severity signal that survives greyscale: glyph first, tint second, name in the accessibility
/// tree. Replaces the bare dot wherever a row's only state indicator was its colour.
struct SeverityMark: View {
    let level: HealthLevel
    /// Rides the row's own text style so it tracks the system text-size setting.
    var font: Font = .callout

    var body: some View {
        Image(systemName: level.symbol)
            .font(font)
            .foregroundStyle(level.markTint)
            .accessibilityLabel(Format.health(level))
    }
}

extension LiveMetrics {
    /// The most severe Firing Alert Rule's level; nil when none fires.
    var worstFiringSeverity: HealthLevel? {
        alertRules.filter { firingAlertIDs.contains($0.id) }.map(\.severity.health).max()
    }

    /// "Memory under pressure · since 13:58" — the Concern banner's headline.
    func concernHeadline(_ concern: Concern) -> String {
        var title = Format.concernTitle(concern.signal, offline: networkHealth?.connectivity == .offline)
        if let since = started(concern) {
            title += " · since \(since.formatted(date: .omitted, time: .shortened))"
        }
        return title
    }

    /// What the Concern's signal measures right now. Parts this Mac does not report are left out.
    func concernFigures(_ signal: ConcernSignal) -> String? {
        switch signal {
        case .cpu:
            guard let cpu else { return nil }
            var line = "\(Format.percent(cpu.totalPercent)) in use"
            if let top = topProcesses(byCPU: 1).first {
                line += "; \(top.name) is busiest at \(Format.decimal(top.cpuPercent, places: 0))%"
            }
            return line + "."
        case .memory:
            guard let memory else { return nil }
            var line = "\(Format.gigabytes(memory.usedBytes, places: 1)) of \(Format.gigabytes(memory.totalBytes, places: 0)) GB in use"
            if memory.swapUsedBytes > 0 { line += ", \(Format.gigabytes(memory.swapUsedBytes, places: 1)) GB swap" }
            return line + "."
        case .internet:
            guard let h = networkHealth else { return nil }
            if h.connectivity == .offline { return "No route to the internet." }
            let parts = [h.internet?.latencyMs.map { "\(Int($0.rounded())) ms latency" },
                         h.internet?.lossPercent.map { "\(Format.percent($0)) packet loss" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ", ") + "."
        case .battery:
            guard let battery else { return nil }
            let capacity = battery.maximumCapacityPercent.map { ", maximum capacity \(Format.percent($0))" } ?? ""
            return "macOS recommends service\(capacity)."
        case .thermal:
            guard let thermal else { return nil }
            let celsius = sensors?.cpuCelsius.map { ", CPU at \(Format.celsius($0))" } ?? ""
            return "Thermal state \(Format.thermal(thermal))\(celsius)."
        }
    }
}
