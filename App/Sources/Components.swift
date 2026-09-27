import SwiftUI
import Charts
import PulseCore

/// One accent color and symbol per metric family, shared by the popover, cards, charts and sidebar
/// so a metric looks the same everywhere (mockup palette; adapts to Light/Dark via system colors).
enum MetricStyle {
    case cpu, memory, network, upload, disk, battery, temperature, internet, gpu, processes, developer, timeline, alerts
    /// Sensor temperatures (Sensors page): SSD and battery get their own tints so chart lines stay distinct.
    case ssdTemperature, batteryTemperature

    var tint: Color {
        switch self {
        case .cpu, .upload, .internet: .blue
        case .memory: .purple
        case .network, .battery: .green
        case .disk: .indigo
        case .temperature: .orange
        case .gpu: .teal
        case .processes, .timeline: .secondary
        case .developer: .brown
        case .alerts: .red
        case .ssdTemperature: .teal
        case .batteryTemperature: .yellow
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .upload: "arrow.up"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .temperature: "thermometer.medium"
        case .internet: "globe"
        case .gpu: "square.stack.3d.up"
        case .processes: "list.bullet.rectangle"
        case .developer: "hammer"
        case .timeline: "clock"
        case .alerts: "bell"
        case .ssdTemperature: "internaldrive"
        case .batteryTemperature: "battery.75percent"
        }
    }
}

extension MetricStyle {
    /// Stepped shades of the one metric tint, for charts with several parts of the same family
    /// (memory ring and bands, per-core lines). Keeps the one-tint-per-metric rule intact.
    ///
    /// Opacity alone is not enough: over a dark background every step still reads as the same
    /// bright hue. Desaturating while lightening walks the tint from deep to pale, which separates
    /// in both appearances.
    func shade(_ index: Int, of count: Int) -> Color {
        guard count > 1, let base = NSColor(tint).usingColorSpace(.deviceRGB) else { return tint }
        let step = Double(min(index, count - 1)) / Double(count - 1)
        return Color(hue: Double(base.hueComponent),
                     saturation: Double(base.saturationComponent) * (1 - 0.7 * step),
                     brightness: min(Double(base.brightnessComponent) * (1 + 0.4 * step), 1))
    }
}

// MARK: - Sparkline

/// Shape-only trend line with a gradient fill. Plots the last `points` values; fewer values sit at the right edge.
struct Sparkline: View {
    struct Series: Identifiable {
        let name: String
        let values: [Double]
        let tint: Color
        var id: String { name }
    }

    let series: [Series]
    /// Number of x slots; the newest value is always at the right edge.
    var points = 60
    /// Fixed y range (e.g. 0...100 for percentages); nil fits the data.
    var domain: ClosedRange<Double>?
    var height: CGFloat = 50

    init(values: [Double], tint: Color, points: Int = 60, domain: ClosedRange<Double>? = nil, height: CGFloat = 50) {
        self.init(series: [Series(name: "value", values: values, tint: tint)], points: points, domain: domain, height: height)
    }

    init(series: [Series], points: Int = 60, domain: ClosedRange<Double>? = nil, height: CGFloat = 50) {
        self.series = series
        self.points = points
        self.domain = domain
        self.height = height
    }

    var body: some View {
        Chart {
            ForEach(series) { s in
                let tail = Array(s.values.suffix(points))
                let offset = points - tail.count
                ForEach(Array(tail.enumerated()), id: \.offset) { index, value in
                    if !value.isNaN {
                        AreaMark(x: .value("t", offset + index), yStart: .value("base", yDomain.lowerBound),
                                 yEnd: .value("v", value), series: .value("s", s.name))
                            .foregroundStyle(LinearGradient(colors: [s.tint.opacity(0.35), s.tint.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("t", offset + index), y: .value("v", value), series: .value("s", s.name))
                            .foregroundStyle(s.tint)
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(points - 1, 1))
        .chartYScale(domain: yDomain)
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var yDomain: ClosedRange<Double> {
        if let domain { return domain }
        let values = series.flatMap { $0.values.suffix(points) }.filter { !$0.isNaN }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.15, 0.5)
        return max(low - pad, 0)...(high + pad)
    }
}

// MARK: - Cards

extension View {
    /// Rounded card surface used by every dashboard section.
    func cardBackground(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// Tinted icon + title + optional Health badge, then free-form content (value, sparkline, footer).
struct MetricCard<Content: View>: View {
    let title: String
    let style: MetricStyle
    var health: HealthLevel?
    var healthLabel: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol).foregroundStyle(style.tint).font(.title3).frame(width: 24)
                Text(title).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                if let health { HealthBadge(level: health, label: healthLabel).fixedSize() }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

struct BigValue: View {
    let text: String?
    init(_ text: String?) { self.text = text }

    var body: some View {
        Text(text ?? "--").font(.title.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// Mockup card footer: equal columns of value over caption.
struct FooterStats: View {
    struct Stat: Identifiable {
        let label: String
        let value: String?
        var dot: Color?
        var id: String { label }
    }

    let stats: [Stat]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let dot = stat.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                        Text(stat.label).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.caption)
                    Text(stat.value ?? "--").font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .minimumScaleFactor(0.75)
            }
        }
    }
}

/// Statistics rail beside a chart. A row whose value is nil is **omitted**: a figure this Mac cannot
/// report must not look like a reading that broke (ADR 0002's fail-soft rule, applied to the UI).
struct StatRail: View {
    struct Row: Identifiable {
        let label: String
        let value: String?
        var id: String { label }
    }

    let rows: [Row]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(rows.filter { $0.value != nil }) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.value ?? "").monospacedDigit().lineLimit(1)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .minimumScaleFactor(0.8)
    }
}

/// "↑ 5% vs 5m avg" on a summary card. Nil (a series too short to have a trend) draws nothing,
/// and changes below the noise floor are not worth an arrow.
struct DeltaLabel: View {
    let value: Double?
    var format: (Double) -> String = { Format.percent(abs($0)) }
    /// All four Performance cards measure load, so rising is the direction worth noticing.
    var noiseFloor: Double = 0.5

    var body: some View {
        if let value, abs(value) >= noiseFloor {
            HStack(spacing: 3) {
                Image(systemName: value > 0 ? "arrow.up" : "arrow.down")
                    .foregroundStyle(value > 0 ? Color.orange : Color.green)
                Text(format(value)).monospacedDigit()
                Text("vs 5m avg").foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// Ring of parts that add up to a whole, with the headline figure in the middle.
struct DonutChart: View {
    struct Slice: Identifiable {
        let label: String
        let value: Double
        let tint: Color
        var id: String { label }
    }

    let slices: [Slice]
    let centerValue: String
    let centerCaption: String
    var diameter: CGFloat = 150

    var body: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value(slice.label, slice.value), innerRadius: .ratio(0.68), angularInset: 1.5)
                .foregroundStyle(slice.tint)
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 1) {
                Text(centerValue).font(.title3.weight(.semibold)).monospacedDigit()
                Text(centerCaption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(centerValue) \(centerCaption)")
    }
}

/// Chart with its statistics rail beside it, dropping the rail underneath when the window is narrow
/// (the dashboard's minimum width is 980).
struct ChartWithRail<Content: View>: View {
    let rail: StatRail
    var railWidth: CGFloat = 230
    @ViewBuilder let chart: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                chart.frame(minWidth: 420)
                rail.frame(width: railWidth)
            }
            VStack(alignment: .leading, spacing: 14) {
                chart
                rail
            }
        }
    }
}

// MARK: - Headers

/// In-content page title for every dashboard section (the window title bar is hidden).
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String?) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Heading for a group inside a page.
struct SubsectionHeader: View {
    let title: String
    let subtitle: String?
    init(_ title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
    }
}

/// Mockup brand mark: pulse glyph on a blue rounded square.
struct AppLogo: View {
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.6, blue: 1), Color(red: 0.1, green: 0.35, blue: 0.95)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Process icons

/// App icons for GUI processes, generic executable icon otherwise. Looked up once per PID.
@MainActor
final class IconCache {
    private var cache: [Int32: NSImage] = [:]
    private let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for pid: Int32) -> NSImage {
        if let cached = cache[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? generic
        cache[pid] = icon
        return icon
    }
}
