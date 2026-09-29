import SwiftUI
import Charts
import PulseCore
import PulseCollectors
import PulseEngine

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

    /// The card surface each appearance draws (`Palette.card`). Ink is measured against the card
    /// rather than the window because the card is where status text sits.
    enum Surface {
        static let light = (1.0, 1.0, 1.0)
        static let dark = (0.133, 0.133, 0.149)
    }

    /// `alpha` of `color` over `surface` — what a tinted capsule fill actually measures. Ink drawn
    /// on such a fill has to be compared against this, not against the tint it was mixed from.
    static func composite(_ color: (Double, Double, Double), alpha: Double,
                          over surface: (Double, Double, Double)) -> (Double, Double, Double) {
        (color.0 * alpha + surface.0 * (1 - alpha),
         color.1 * alpha + surface.1 * (1 - alpha),
         color.2 * alpha + surface.2 * (1 - alpha))
    }

    /// The tint re-lit until it clears `minimum` against `background`, keeping its own hue.
    ///
    /// Ink and fill taken from one system colour is the trap: at the tint's own lightness the pair
    /// measures under 2:1 in Light. Walking lightness *away* from the background is the same move
    /// `shade` makes, for the same reason — and returning the tint untouched when it already clears
    /// the floor keeps the appearance that was already correct exactly as it was.
    static func ink(for rgb: (Double, Double, Double), on background: (Double, Double, Double),
                    dark: Bool, minimum: Double) -> (Double, Double, Double) {
        guard contrast(rgb, background) < minimum else { return rgb }
        let (_, chroma, hue) = toOKLCH(rgb)
        let (bound, direction) = dark ? (0.98, 1.0) : (0.12, -1.0)
        var lightness = toOKLCH(rgb).l
        var last = rgb
        while (direction > 0 && lightness < bound) || (direction < 0 && lightness > bound) {
            lightness = min(max(lightness + direction * 0.01, 0), 1)
            // Chroma has to fall as lightness approaches either extreme, or the colour turns
            // garish and leaves the sRGB gamut.
            let headroom = 1 - pow(abs(lightness - 0.5) * 2, 2)
            last = toSRGB(lightness: lightness, chroma: max(chroma, 0.04) * (0.55 + 0.45 * headroom),
                          hue: hue)
            if contrast(last, background) >= minimum { return last }
        }
        return last
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

extension Color {
    /// What this colour sits on when it has to stay readable.
    enum Backdrop {
        case card
        /// A fill mixed from this same colour at `alpha` — the status capsule and thermal banner.
        case tintedFill(Double)
    }

    /// This colour re-lit for the appearance it is drawn in, so meaning carried by colour survives
    /// both. A tint that already clears `minimum` is returned untouched.
    func readableInk(on backdrop: Backdrop, minimum: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var resolved = NSColor.textColor
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(self).usingColorSpace(.sRGB) ?? .textColor
            }
            let tint = (Double(resolved.redComponent), Double(resolved.greenComponent),
                        Double(resolved.blueComponent))
            let surface = dark ? OKLCH.Surface.dark : OKLCH.Surface.light
            let background = switch backdrop {
            case .card: surface
            case .tintedFill(let alpha): OKLCH.composite(tint, alpha: alpha, over: surface)
            }
            let rgb = OKLCH.ink(for: tint, on: background, dark: dark, minimum: minimum)
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

// MARK: - Palette

/// The dashboard's surfaces, after `docs/prd/Redesign_v1.html`. The design is dark-only; the Dark
/// values are its hex codes, and Light mirrors them (grey window, white cards) so both appearances
/// keep the same layering: window, then sidebar, then card on top.
enum Palette {
    /// Detail pane and toolbar. Design `#1a1a1d`.
    static let window = dynamic(light: 0xF5F5F7, dark: 0x1A1A1D)
    /// Sidebar column. Design `#1f1f23`.
    static let sidebar = dynamic(light: 0xECECEF, dark: 0x1F1F23)
    /// Cards and tiles. Design `#222226`; `OKLCH.Surface` holds the same values for contrast checks.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x222226)
    /// Card outline. Design `#2c2c32`.
    static let cardBorder = dynamic(light: 0xE2E2E6, dark: 0x2C2C32)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Curve

/// The curve every line chart draws: through each sample, never past it. Monotone, so a line
/// cannot dip below zero or show a peak that was not measured.
enum ChartCurve {
    static let line: InterpolationMethod = .monotone
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
    var lineWidth: CGFloat = 1.4

    init(values: [Double], tint: Color, points: Int = 60, domain: ClosedRange<Double>? = nil, height: CGFloat = 50,
         lineWidth: CGFloat = 1.4) {
        self.init(series: [Series(name: "value", values: values, tint: tint)], points: points, domain: domain,
                  height: height, lineWidth: lineWidth)
    }

    init(series: [Series], points: Int = 60, domain: ClosedRange<Double>? = nil, height: CGFloat = 50,
         lineWidth: CGFloat = 1.4) {
        self.series = series
        self.points = points
        self.domain = domain
        self.height = height
        self.lineWidth = lineWidth
    }

    /// Top of a percentage sparkline's scale: the peak plus 25% headroom, in steps of 10, never
    /// below 30 (so a 3% load does not fill the chart and read like a busy Mac) or above 100.
    /// Stepping means the scale only moves when the peak crosses a step, not on every tick.
    static func percentTop(_ values: [Double]) -> Double {
        let peak = values.filter { $0.isFinite }.max() ?? 0
        return min(100, max(30, (peak * 1.25 / 10).rounded(.up) * 10))
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
                            .interpolationMethod(ChartCurve.line)
                            .foregroundStyle(LinearGradient(colors: [s.tint.opacity(0.35), s.tint.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("t", offset + index), y: .value("v", value), series: .value("s", s.name))
                            .interpolationMethod(ChartCurve.line)
                            .foregroundStyle(s.tint)
                            .lineStyle(StrokeStyle(lineWidth: lineWidth))
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

// MARK: - Meter

/// A share of a whole as a filled capsule: memory in use, battery charge, a process's slice.
struct MeterBar: View {
    /// 0...1; values outside are clamped, so a process above one core saturates the bar.
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * min(max(fraction.isNaN ? 0 : fraction, 0), 1))
                }
            }
            .accessibilityHidden(true)
    }
}

/// Parts of one whole side by side in one capsule: memory's App, Wired and Compressed. The rest of
/// the track is what the parts leave. Silent to VoiceOver — the figures sit beside it as text.
struct StackedMeter: View {
    struct Segment {
        let fraction: Double
        let tint: Color
    }

    let segments: [Segment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let usable = max(geometry.size.width - gap * CGFloat(max(segments.count - 1, 0)), 0)
            HStack(spacing: gap) {
                ForEach(segments.indices, id: \.self) { index in
                    let fraction = segments[index].fraction
                    Rectangle().fill(segments[index].tint)
                        .frame(width: usable * min(max(fraction.isNaN ? 0 : fraction, 0), 1))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(.quaternary)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Rounded usage bar with a gradient fill (storage volumes, per-core rows).
struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Used")
        .accessibilityValue(Format.percent(fraction * 100))
    }
}

/// A headline figure: the number carries the weight, its unit sits small beside it.
struct FigureText: View {
    let number: String
    let unit: String?
    var size: Font = .title2
    var unitSize: Font = .caption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(number).font(size.weight(.semibold))
            if let unit { Text(unit).font(unitSize).foregroundStyle(.secondary) }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// One row per logical core, one column per recent sample, shaded by load: many cores read at a
/// glance where as many lines tangle. Rows are numbered, not labelled P/E — which core belongs to
/// which cluster is not reported. Silent to VoiceOver; the rail beside it carries the figures.
struct CoreHeatmap: View {
    /// Per core, oldest first, 0...100.
    let cores: [[Double]]
    let tint: Color
    var columns = 60
    var rowHeight: CGFloat = 7

    var body: some View {
        Canvas { context, size in
            guard !cores.isEmpty, columns > 0 else { return }
            let pitch = size.width / CGFloat(columns)
            // Cells read as cells only when they are wide enough; a full live window is a strip.
            let gap: CGFloat = pitch >= 5 ? 1 : 0
            for (row, values) in cores.enumerated() {
                let y = CGFloat(row) * (rowHeight + 1)
                let tail = values.suffix(columns)
                let offset = columns - tail.count
                // One fill for the row's idle shade, then only the samples that carry load: at rest
                // most cores are idle, and a fill per cell per second is the page's main drawing cost.
                let start = CGFloat(offset) * pitch
                context.fill(Path(CGRect(x: start, y: y, width: size.width - start, height: rowHeight)),
                             with: .color(tint.opacity(0.08)))
                for (index, value) in tail.enumerated() where value >= 2 {
                    let rect = CGRect(x: CGFloat(offset + index) * pitch, y: y, width: pitch - gap, height: rowHeight)
                    context.fill(Path(rect), with: .color(tint.opacity(0.92 * min(value / 100, 1))))
                }
            }
        }
        .frame(height: CGFloat(cores.count) * (rowHeight + 1))
        .accessibilityHidden(true)
    }
}


/// Children side by side at fixed shares of the width (equal by default), all as tall as the
/// tallest. `Grid` cannot do a 5:7 split, and an `HStack` hands width to whichever child asks.
struct WeightedHStack: Layout {
    var weights: [CGFloat] = []
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let height = zip(subviews, widths(width, count: subviews.count))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    /// Weights that do not match the child count (a tile hidden on this Mac) fall back to equal shares.
    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let shares = weights.count == count ? weights : Array(repeating: 1, count: count)
        let usable = max(total - spacing * CGFloat(count - 1), 0)
        let sum = shares.reduce(0, +)
        return shares.map { usable * $0 / sum }
    }
}

// MARK: - Cards

extension View {
    /// Rounded card surface used by every dashboard section.
    func cardBackground(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardBorder, lineWidth: 1))
    }
}

/// Tinted icon + title + optional Health badge, then free-form content (value, sparkline, footer).
struct MetricCard<Content: View>: View {
    let title: String
    let style: MetricStyle
    var health: HealthLevel?
    var healthLabel: String?
    /// Washes the whole card in its Health Level's tint while Warning or Critical, so the card in
    /// trouble is found before any label is read (Overview's headline row).
    var emphasizesHealth = false
    @ViewBuilder let content: Content

    /// Matches the Concern banner's wash, so the card and the banner above it read as one signal.
    static var emphasisFill: Double { 0.12 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol).foregroundStyle(style.tint).font(.title3).frame(width: 24)
                // At the 980pt window minimum a three-up grid leaves long titles a few points
                // short. Shrinking the title slightly keeps the word; an ellipsis loses it.
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if let health { HealthBadge(level: health, label: healthLabel).fixedSize() }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background {
            shape.fill(Palette.card)
            if let emphasis { shape.fill(emphasis.tint.opacity(Self.emphasisFill)) }
        }
        .overlay {
            if let emphasis {
                shape.strokeBorder(emphasis.tint.opacity(0.35), lineWidth: 0.5)
            } else {
                shape.strokeBorder(Palette.cardBorder, lineWidth: 1)
            }
        }
    }

    private var emphasis: HealthLevel? {
        guard emphasizesHealth, let health, health >= .warning else { return nil }
        return health
    }
}

/// A card's headline figure. There is no dash: a figure that does not exist yet is replaced by one
/// line saying what is coming (the same contract `TimeSeriesChart` uses for an empty plot), and a
/// figure this Mac cannot report at all is not drawn by this view — the card says so in its own words.
struct BigValue: View {
    let text: String?
    /// Shown in place of the figure until the first reading lands.
    var awaiting: String = "Reading…"

    init(_ text: String?, awaiting: String = "Reading…") {
        self.text = text
        self.awaiting = awaiting
    }

    var body: some View {
        if let text {
            Text(text).font(.title.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        } else {
            Text(awaiting)
                .font(.callout)
                .foregroundStyle(.secondary)
                // Hold the headline's height so the card does not jump when the reading arrives.
                .frame(height: NSFont.preferredFont(forTextStyle: .title1).boundingRectForFont.height,
                       alignment: .leading)
        }
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
            // Same rule as `StatRail`: a figure this Mac cannot report is absent, not dashed.
            ForEach(stats.filter { $0.value != nil }) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let dot = stat.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                        Text(stat.label).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.caption)
                    Text(stat.value ?? "").font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
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
                // Direction is the whole signal; status colour belongs to Health Level alone, and a
                // 0.6% tick painted orange trains the user to ignore the colour that matters.
                Image(systemName: value > 0 ? "arrow.up" : "arrow.down")
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
/// "Nothing here" *inside* a card, where `ContentUnavailableView`'s centred layout would be too
/// loud. Five sections used to write this line by hand; the difference in intent from the
/// section-level empty state is scale, so the two stay separate and each stays consistent.
struct InlineEmpty: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppLogo: View {
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            // The app icon's own gradient (#3B7BFF → #1D3FD6, Redesign_v1), so the in-app mark matches it.
            .fill(LinearGradient(colors: [Color(red: 0x3B / 255, green: 0x7B / 255, blue: 1),
                                          Color(red: 0x1D / 255, green: 0x3F / 255, blue: 0xD6 / 255)],
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

// MARK: - Concern

/// The Concern as a tinted banner: headline and start, what the signal measures now, and what is
/// still healthy. The Popover shows it bare; the Overview adds actions at the trailing edge.
struct ConcernBanner<Actions: View>: View {
    let concern: Concern
    let metrics: LiveMetrics
    /// The Overview's larger variant.
    var prominent = false
    @ViewBuilder let actions: Actions

    private static var fill: Double { MetricCard<EmptyView>.emphasisFill }

    var body: some View {
        let ink = concern.level.tint.readableInk(on: .tintedFill(Self.fill), minimum: 4.5)
        let shape = RoundedRectangle(cornerRadius: prominent ? 12 : 10, style: .continuous)
        HStack(alignment: prominent ? .center : .top, spacing: prominent ? 14 : 10) {
            Image(systemName: concern.level.symbol)
                .font(prominent ? .title2 : .title3)
                .foregroundStyle(concern.level.tint.readableInk(on: .tintedFill(Self.fill), minimum: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(metrics.concernHeadline(concern))
                    .font((prominent ? Font.body : .callout).weight(.semibold))
                    .foregroundStyle(ink)
                // The Overview keeps it to one sentence: figures, then what is still fine.
                if prominent {
                    let line = [metrics.concernFigures(concern.signal), Format.healthyLine(concern.healthy)]
                        .compactMap { $0 }.joined(separator: " ")
                    if !line.isEmpty { Text(line).font(.callout).foregroundStyle(.secondary) }
                } else {
                    if let figures = metrics.concernFigures(concern.signal) { Text(figures).font(.caption) }
                    if let healthy = Format.healthyLine(concern.healthy) {
                        Text(healthy).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            actions
        }
        .padding(prominent ? 14 : 12)
        .background(concern.level.tint.opacity(Self.fill), in: shape)
        .overlay(shape.strokeBorder(concern.level.tint.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

extension ConcernBanner where Actions == EmptyView {
    init(concern: Concern, metrics: LiveMetrics) {
        self.init(concern: concern, metrics: metrics, actions: { EmptyView() })
    }
}

// MARK: - Top processes

/// Which figure ranks the Top Processes list.
enum ProcessSort: String, CaseIterable {
    case cpu = "CPU", memory = "Memory"
}

/// The busiest processes by CPU or memory: icon, name, share bar, figure. A process holding a whole
/// core or more is drawn red — that is the one to look at. Callers own the process-list gate.
struct TopProcessList: View {
    let metrics: LiveMetrics
    @Binding var sort: ProcessSort
    var count = 5
    @State private var icons = IconCache()

    var body: some View {
        let rows = sort == .cpu ? metrics.topProcesses(byCPU: count) : metrics.topProcesses(byMemory: count)
        let total = Double(max(metrics.memory?.totalBytes ?? 0, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top processes").font(.headline)
                Spacer()
                Picker("Sort by", selection: $sort) {
                    ForEach(ProcessSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            ForEach(rows) { process in
                let hot = sort == .cpu && process.cpuPercent >= 100
                let tint = hot ? Color.red : (sort == .cpu ? MetricStyle.cpu.tint : MetricStyle.memory.tint)
                HStack(spacing: 8) {
                    Image(nsImage: icons.icon(for: process.pid)).resizable().frame(width: 16, height: 16)
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    MeterBar(fraction: sort == .cpu ? process.cpuPercent / 100 : Double(process.memoryBytes) / total,
                             tint: tint, height: 4)
                        .frame(width: 100)
                    Text(sort == .cpu ? "\(Format.decimal(process.cpuPercent, places: 1))%" : Format.memory(process.memoryBytes))
                        .monospacedDigit()
                        .foregroundStyle(hot ? Color.red.readableInk(on: .card, minimum: 4.5) : Color.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
