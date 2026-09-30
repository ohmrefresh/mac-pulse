import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

/// Battery page (after `docs/prd/mock_v2.html`): charge now and how long it lasts, stored charge
/// over the chosen range, Battery Condition and wear, and accessory batteries. A Mac without an
/// internal battery shows only its accessories.
struct BatteryView: View {
    let metrics: LiveMetrics
    @State private var range: ChartRange = .day
    @Environment(\.temperatureUnit) private var unit

    /// The spans the charge chart offers: charge moves over hours and days, not minutes.
    static let ranges: [ChartRange] = [.day, .week, .month]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let b = metrics.battery {
                    WeightedHStack(weights: [1, 2]) {
                        hero(b)
                        chargeCard
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    WeightedHStack(weights: [1, 1]) {
                        health(b)
                        accessories
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    accessories
                    Label("This Mac has no internal battery.", systemImage: "powerplug")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .toolbar {
            if metrics.battery != nil {
                ToolbarItem(placement: .primaryAction) {
                    ChartRangePicker(range: $range, options: Self.ranges)
                }
            }
        }
    }

    // MARK: Hero

    private func hero(_ b: BatteryReading) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(BatteryPhrase.state(b, unpluggedAt: unpluggedAt(b)),
                  systemImage: b.onACPower ? "bolt.fill" : "battery.75percent")
                .font(.callout).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            FigureText(number: "\(Int(b.percent.rounded()))", unit: "%", size: .system(size: 44), unitSize: .title3)
            MeterBar(fraction: b.percent / 100, tint: MetricStyle.battery.tint, height: 10)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                KeyValue("Time remaining", b.minutesRemaining.map { Format.duration(minutes: $0) })
                KeyValue(b.isCharging ? "Full by" : "Empty by",
                         BatteryPhrase.clockTime(minutesRemaining: b.minutesRemaining, onACPower: b.onACPower,
                                                 isCharging: b.isCharging))
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    /// When the Mac was last unplugged, from this session's power events; nil once plugged in or
    /// when the switch happened before Mac Pulse started.
    private func unpluggedAt(_ b: BatteryReading) -> Date? {
        guard !b.onACPower,
              let last = metrics.recentEvents.last(where: { $0.category == .battery }),
              last.title == TimelineEpisodes.switchedToBatteryTitle else { return nil }
        return last.time
    }

    // MARK: Charge

    private var chargeCard: some View {
        Section2(title: "Charge · last \(range.label)", subtitle: nil) {
            HistoryChart(history: metrics.history,
                         lines: [.init(kind: .batteryPercent, name: "Charge", tint: MetricStyle.battery.tint)],
                         range: range, maximum: 100, format: { "\(Int($0))%" }, showsHoverDetails: true,
                         accessibilityTitle: "Battery charge")
                .frame(minHeight: 180)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Health

    private func health(_ b: BatteryReading) -> some View {
        Section2(title: "Health", subtitle: nil) {
            if let condition = b.condition {
                HealthBadge(level: condition.health, label: Format.batteryCondition(condition))
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if let capacity = b.maximumCapacityPercent {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Maximum capacity").foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.percent(capacity)).fontWeight(.semibold).monospacedDigit()
                        }
                        MeterBar(fraction: capacity / 100, tint: MetricStyle.battery.tint)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    KeyValue("Cycle count", b.cycleCount.map { Format.decimal(Double($0), places: 0) })
                    KeyValue("Temperature", metrics.sensors?.batteryCelsius.map { Format.temperature($0, unit) })
                }
            }
            .font(.callout)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Accessories

    private var accessories: some View {
        Section2(title: "Accessories", subtitle: metrics.peripheralBatteries.isEmpty ? nil : "\(metrics.peripheralBatteries.count)") {
            if metrics.peripheralBatteries.isEmpty {
                InlineEmpty("No Bluetooth accessories reporting a battery level.")
            } else {
                VStack(spacing: 10) {
                    ForEach(metrics.peripheralBatteries) { accessory in
                        HStack(spacing: 10) {
                            Text(accessory.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            CellMeter(fraction: Double(accessory.percent) / 100, tint: MetricStyle.battery.tint, width: 80)
                            Text("\(accessory.percent)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The hero card's wording, kept out of the view so it can be tested.
enum BatteryPhrase {
    /// "On battery · unplugged 21:16", "Charging", "On AC".
    static func state(_ b: BatteryReading, unpluggedAt: Date?) -> String {
        if b.isCharging { return "Charging" }
        if b.onACPower { return "On AC" }
        guard let unpluggedAt else { return "On battery" }
        return "On battery · unplugged \(unpluggedAt.formatted(date: .omitted, time: .shortened))"
    }

    /// When the battery empties (on battery) or fills (charging), from macOS's own estimate. Nil
    /// without an estimate, and on AC when not charging (nothing is being counted down).
    /// "08:55", "08:55 tomorrow", later still "Thu 08:55".
    static func clockTime(minutesRemaining: Int?, onACPower: Bool, isCharging: Bool, now: Date = Date(),
                          calendar: Calendar = .current) -> String? {
        guard let minutes = minutesRemaining, isCharging || !onACPower else { return nil }
        let date = now.addingTimeInterval(TimeInterval(minutes) * 60)
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "\(clock) tomorrow"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(clock)"
    }
}
