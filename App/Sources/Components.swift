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
    /// The ramp walks *away* from the background: darker as it steps in Light, lighter in Dark.
    /// A single direction cannot serve both — lightening on white walks into the background, which
    /// is what put the palest memory bands under the 3:1 non-text contrast floor. Steps are spaced
    /// in OKLCH so they look evenly separated rather than evenly numbered.
    func shade(_ index: Int, of count: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var resolved = NSColor.textColor
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(self.tint).usingColorSpace(.sRGB) ?? .textColor
            }
            let rgb = OKLCH.shade(of: (Double(resolved.redComponent), Double(resolved.greenComponent),
                                       Double(resolved.blueComponent)),
                                  index: index, count: count, dark: dark)
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// Perceptual color stepping. HSB steps the same distance twice and look uneven; OKLCH lightness
/// is perceptually uniform, so a ramp built on it reads as evenly spaced.
enum OKLCH {
    /// Lightness band each appearance ramps across, chosen by sweeping for the widest spread that
    /// still keeps every step at 3:1 against its own background.
    ///
    /// Five steps of one hue cannot also hit 3:1 against *each other* — that geometry does not
    /// exist — so band edges are drawn instead: the ring insets its sectors and the stacked chart
    /// draws a hairline at each boundary. Fills carry the family, boundaries carry the separation.
    static let lightBand = (top: 0.66, bottom: 0.28)
    static let darkBand = (top: 0.56, bottom: 0.92)

    /// Step `index` of `count` along the tint's own hue.
    static func shade(of rgb: (Double, Double, Double), index: Int, count: Int, dark: Bool) -> (Double, Double, Double) {
        let (lightness, chroma, hue) = toOKLCH(rgb)
        guard count > 1 else { return rgb }
        let step = Double(min(max(index, 0), count - 1)) / Double(count - 1)
        let band = dark ? darkBand : lightBand
        let target = band.0 + (band.1 - band.0) * step
        // Chroma has to fall as lightness approaches either extreme or the color turns garish and
        // leaves the sRGB gamut; scale it by how much headroom the target lightness leaves.
        let headroom = 1 - pow(abs(target - 0.5) * 2, 2)
        let scaled = max(chroma, 0.04) * (0.55 + 0.45 * headroom)
        return toSRGB(lightness: target, chroma: scaled, hue: lightness > 0 ? hue : 0)
    }

    static func toOKLCH(_ rgb: (Double, Double, Double)) -> (l: Double, c: Double, h: Double) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear(rgb.0), linear(rgb.1), linear(rgb.2))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (lightness, (a * a + bb * bb).squareRoot(), atan2(bb, a))
    }

    static func toSRGB(lightness: Double, chroma: Double, hue: Double) -> (Double, Double, Double) {
        let a = chroma * cos(hue), b = chroma * sin(hue)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ v: Double) -> Double {
            let c = max(min(v, 1), 0)
            return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return (gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// WCAG relative luminance, for the contrast tests.
    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(rgb.0) + 0.7152 * lin(rgb.1) + 0.0722 * lin(rgb.2)
    }

    static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
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
                // Otherwise VoiceOver reads the label and its value as two unrelated elements.
                .accessibilityElement(children: .combine)
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
            // The bare SF Symbol would otherwise be announced as "arrow up".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value > 0 ? "Up \(format(value))" : "Down \(format(value))")
            .accessibilityHint("Compared with the five minute average")
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
        // Each sector is an element by default; the legend beside the ring already lists every value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(centerValue) \(centerCaption)")
        .accessibilityValue(slices.map { "\($0.label) \(Format.memory(UInt64(max($0.value, 0))))" }
            .joined(separator: ", "))
    }
}

/// Chart with its statistics rail beside it, dropping the rail underneath when the window is narrow
/// (the dashboard's minimum width is 980).
struct ChartWithRail<Content: View>: View {
    let rail: StatRail
    @ViewBuilder let chart: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                chart.frame(minWidth: 420)
                rail.frame(width: 230)
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
            Text(title).font(.title3.weight(.semibold)).fixedSize()
            // Hardware names come from the machine and can be long; truncate rather than shove the
            // section's trailing controls off the edge.
            if let subtitle { Text(subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
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
