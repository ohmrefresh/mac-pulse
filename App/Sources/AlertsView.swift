import SwiftUI
import UserNotifications
import PulseCore
import PulseEngine
import PulseStore

/// After mock_v2: a notice while nothing can notify, the Alert Rules by area or severity with when
/// each last fired, then the alerts that fired.
struct AlertsView: View {
    let metrics: LiveMetrics
    @Bindable var settings: AppSettings
    let notifier: AlertNotifier
    /// Opens the Timeline on the alert category.
    let showTimeline: () -> Void
    @State private var stored: [TimelineEvent] = []
    /// Whether `stored` holds every alert event in the window. "Never" is claimed only when it does.
    @State private var storedComplete = false
    @AppStorage("alertsRuleGrouping") private var grouping = RuleGrouping.area

    private static let storedLimit = 500

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if notifier.authorization == .denied {
                    NoticeBanner(level: .warning, symbol: "bell.slash",
                                 title: "Notifications are turned off for Mac Pulse in System Settings",
                                 detail: "Alerts still appear in the timeline.")
                }
                if enabledCount == 0 {
                    NoticeBanner(level: .warning, symbol: "bell.slash",
                                 title: settings.alertRules.isEmpty
                                     ? "There are no rules — you won't be notified about anything"
                                     : "All \(settings.alertRules.count) rules are off — you won't be notified about anything",
                                 detail: "Turn on a rule below, or add one from the toolbar.")
                }
                rulesCard
                firedCard
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(AlertMetric.allCases, id: \.self) { metric in
                        Button(metric.displayName) { settings.addRule(for: metric) }
                    }
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .help("Add a rule for a metric")
            }
        }
        .navigationSubtitle(metrics.firingAlertIDs.isEmpty ? "" : "\(metrics.firingAlertIDs.count) firing")
        .task { await notifier.refreshAuthorization() }
        .task(id: settings.retention) { await loadStored() }
    }

    private var enabledCount: Int { settings.alertRules.filter(\.isEnabled).count }

    // MARK: Rules

    private var rulesCard: some View {
        let alerts = recentAlerts
        return Section2(title: "Rules", subtitle: "\(settings.alertRules.count) · \(enabledCount) enabled") {
            Picker("Group rules", selection: $grouping) {
                ForEach(RuleGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if settings.alertRules.isEmpty {
                InlineEmpty("No rules. Add one from the toolbar.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    RuleColumns.header
                    Divider().padding(.bottom, 4)
                    ForEach(groups, id: \.title) { group in
                        Text(group.title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(group.rules.enumerated()), id: \.element.id) { index, rule in
                            RuleRow(rule: binding(for: rule),
                                    isFiring: metrics.firingAlertIDs.contains(rule.id),
                                    lastFired: lastFired(rule, in: alerts),
                                    window: windowName,
                                    shaded: index.isMultiple(of: 2),
                                    onDelete: { settings.deleteRule(rule.id) })
                        }
                    }
                }
            }
        }
    }

    private struct RuleGroup {
        let title: String
        let rules: [AlertRule]
    }

    /// Settings order within each group; empty groups are left out.
    private var groups: [RuleGroup] {
        let all: [RuleGroup] = switch grouping {
        case .area:
            RuleArea.allCases.map { area in
                RuleGroup(title: area.title, rules: settings.alertRules.filter { $0.metric.area == area })
            }
        case .severity:
            [AlertSeverity.critical, .warning].map { severity in
                RuleGroup(title: Format.health(severity.health), rules: settings.alertRules.filter { $0.severity == severity })
            }
        }
        return all.filter { !$0.rules.isEmpty }
    }

    /// Reads and writes the rule by id, so a deletion never leaves a row holding a stale index.
    private func binding(for rule: AlertRule) -> Binding<AlertRule> {
        Binding {
            settings.alertRules.first { $0.id == rule.id } ?? rule
        } set: { updated in
            guard let index = settings.alertRules.firstIndex(where: { $0.id == rule.id }) else { return }
            settings.alertRules[index] = updated
        }
    }

    /// The latest fire in the window, matched the way `LiveMetrics.timelineEvent(for:)` titles it: a
    /// non-Healthy alert event titled with the rule's name. Unknown when two rules share the name or
    /// the window was not read in full.
    private func lastFired(_ rule: AlertRule, in alerts: [TimelineEvent]) -> LastFired {
        guard settings.alertRules.filter({ $0.name == rule.name }).count == 1 else { return .unknown }
        if let fire = alerts.first(where: { $0.severity > .healthy && $0.title == rule.name }) { return .at(fire.time) }
        return storedComplete ? .never : .unknown
    }

    // MARK: Fired alerts

    private var firedCard: some View {
        let alerts = recentAlerts
        return Section2(title: "Fired alerts", subtitle: windowName) {
            Button("Open timeline", action: showTimeline).buttonStyle(.link)
        } content: {
            if alerts.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "bell").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(enabledCount == 0 ? "Nothing fired — no rules are enabled" : "Nothing fired")
                            .fontWeight(.medium)
                        Text(enabledCount == 0
                             ? "Turn on a rule and its alerts will appear here, with a notification."
                             : "No rule fired in the \(windowName).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(alerts.prefix(50).enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider() }
                        EventRow(event: event).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// Alert events are kept no longer than the retention setting, so the window is the shorter of the two.
    private var window: TimeInterval { min(7 * 86_400, TimeInterval(settings.retention.rawValue)) }

    private var windowName: String {
        switch window {
        case ..<3_601: "last hour"
        case ..<21_601: "last 6 hours"
        case ..<86_401: "last 24 hours"
        default: "last 7 days"
        }
    }

    /// Stored alert events plus live ones not yet flushed, newest first.
    private var recentAlerts: [TimelineEvent] {
        let cutoff = Date().addingTimeInterval(-window)
        let storedIDs = Set(stored.map(\.id))
        let live = metrics.recentEvents.filter { $0.category == .alert && $0.time >= cutoff && !storedIDs.contains($0.id) }
        return (live + stored).sorted { $0.time > $1.time }
    }

    private func loadStored() async {
        guard let history = metrics.history else { stored = []; storedComplete = false; return }
        let from = Date().addingTimeInterval(-window)
        let limit = Self.storedLimit
        do {
            stored = try await Task.detached {
                try history.events(from: from, to: Date(), categories: [.alert], limit: limit)
            }.value
            storedComplete = stored.count < limit
        } catch {
            stored = []
            storedComplete = false
        }
    }
}

// MARK: - Grouping and wording

enum RuleGrouping: String, CaseIterable {
    case area, severity

    var title: String { self == .area ? "By area" : "By severity" }
}

/// What part of the Mac a rule watches.
enum RuleArea: CaseIterable {
    case compute, thermal, networkAndDisk, power

    var title: String {
        switch self {
        case .compute: "Compute"
        case .thermal: "Thermal"
        case .networkAndDisk: "Network & disk"
        case .power: "Power"
        }
    }
}

extension AlertMetric {
    var area: RuleArea {
        switch self {
        case .cpuPercent, .gpuPercent, .memoryPressure: .compute
        case .thermalState, .cpuTemperatureC: .thermal
        case .latencyMs, .packetLossPercent, .diskFreeGB: .networkAndDisk
        case .batteryPercent: .power
        }
    }

    var style: MetricStyle {
        switch self {
        case .cpuPercent: .cpu
        case .gpuPercent: .gpu
        case .memoryPressure: .memory
        case .thermalState, .cpuTemperatureC: .temperature
        case .latencyMs, .packetLossPercent: .network
        case .diskFreeGB: .disk
        case .batteryPercent: .battery
        }
    }
}

/// A rule's condition as a sentence: "CPU" "above 90%" "30 s", or no duration for "immediately".
enum RulePhrase {
    static func parts(_ rule: AlertRule, unit: TemperatureUnit = .celsius) -> (subject: String, condition: String, duration: String?) {
        // Memory pressure and Thermal State are steps, not quantities: they "reach" a level.
        let stepped = rule.metric == .memoryPressure || rule.metric == .thermalState
        let comparison = switch rule.comparator {
        case .above: "above"
        case .atLeast: stepped ? "reaches" : "at or above"
        case .below: "below"
        case .atMost: "at or below"
        }
        return (rule.metric.displayName, "\(comparison) \(Format.alertThreshold(rule.metric, rule.threshold, unit: unit))",
                rule.duration > 0 ? Format.lasted(rule.duration) : nil)
    }

    /// The sentence with the condition and duration in bold.
    static func text(_ rule: AlertRule, unit: TemperatureUnit = .celsius) -> AttributedString {
        let p = parts(rule, unit: unit)
        var condition = AttributedString(p.condition)
        condition.inlinePresentationIntent = .stronglyEmphasized
        var sentence = AttributedString("\(p.subject) ") + condition
        if let duration = p.duration {
            var held = AttributedString(duration)
            held.inlinePresentationIntent = .stronglyEmphasized
            sentence += AttributedString(" for ") + held
        } else {
            sentence += AttributedString(" · immediately")
        }
        return sentence
    }
}

enum LastFired: Equatable {
    case at(Date)
    case never
    /// Not knowable from what was read; the column stays empty.
    case unknown
}

// MARK: - Rows

/// Column widths shared by the header and every row.
private enum RuleColumns {
    static let toggle: CGFloat = 40
    static let rule: CGFloat = 210
    static let severity: CGFloat = 96
    static let lastFired: CGFloat = 110
    static let edit: CGFloat = 28
    static let spacing: CGFloat = 12

    static var header: some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: toggle, height: 1)
            Text("Rule").frame(width: rule, alignment: .leading)
            Text("Fires when").frame(maxWidth: .infinity, alignment: .leading)
            Text("Severity").frame(width: severity, alignment: .leading)
            Text("Last fired").frame(width: lastFired, alignment: .leading)
            Color.clear.frame(width: edit, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }
}

private struct RuleRow: View {
    @Binding var rule: AlertRule
    let isFiring: Bool
    let lastFired: LastFired
    let window: String
    let shaded: Bool
    let onDelete: () -> Void
    @State private var editing = false
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        HStack(spacing: RuleColumns.spacing) {
            Toggle("", isOn: $rule.isEnabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .accessibilityLabel("\(rule.name) enabled")
                .frame(width: RuleColumns.toggle, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: rule.metric.style.symbol).foregroundStyle(rule.metric.style.tint).frame(width: 18)
                Text(rule.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                if isFiring { HealthBadge(level: rule.severity.health, label: "Firing").fixedSize() }
            }
            .frame(width: RuleColumns.rule, alignment: .leading)
            Text(RulePhrase.text(rule, unit: unit))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HealthStatus(level: rule.severity.health)
                .frame(width: RuleColumns.severity, alignment: .leading)
            lastFiredText
                .frame(width: RuleColumns.lastFired, alignment: .leading)
            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit rule")
                .accessibilityLabel("Edit \(rule.name)")
                .frame(width: RuleColumns.edit)
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    RuleEditor(rule: $rule, unit: unit, onDelete: {
                        editing = false
                        onDelete()
                    })
                }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(shaded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var lastFiredText: some View {
        switch lastFired {
        case .at(let time):
            Text(Format.lastFired(time)).monospacedDigit()
        case .never:
            Text("Never").foregroundStyle(.secondary).help("Not fired in the \(window)")
        case .unknown:
            EmptyView()
        }
    }
}

/// A rule's name, condition, duration and severity, and deleting it.
private struct RuleEditor: View {
    @Binding var rule: AlertRule
    /// Temperature thresholds are entered in this unit and stored in °C.
    let unit: TemperatureUnit
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Name", text: $rule.name).labelsHidden()
                }
                GridRow {
                    Text("Fires when").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(rule.metric.displayName)
                        Picker("", selection: $rule.comparator) {
                            Text(">").tag(AlertComparator.above)
                            Text("≥").tag(AlertComparator.atLeast)
                            Text("<").tag(AlertComparator.below)
                            Text("≤").tag(AlertComparator.atMost)
                        }
                        .labelsHidden()
                        .fixedSize()
                        thresholdEditor
                    }
                }
                GridRow {
                    Text("For").foregroundStyle(.secondary)
                    Stepper(rule.duration == 0 ? "immediately" : "\(Int(rule.duration)) s",
                            value: $rule.duration, in: 0...600, step: 5)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Severity").foregroundStyle(.secondary)
                    Picker("", selection: $rule.severity) {
                        Text("Warning").tag(AlertSeverity.warning)
                        Text("Critical").tag(AlertSeverity.critical)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Divider()
            Button("Delete Rule…", role: .destructive) { confirmDelete = true }
                .confirmationDialog("Delete “\(rule.name)”?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive, action: onDelete)
                }
        }
        .padding(16)
        .frame(width: 380)
    }

    @ViewBuilder
    private var thresholdEditor: some View {
        switch rule.metric {
        case .memoryPressure:
            Picker("", selection: $rule.threshold) {
                Text("Warning").tag(Double(HealthLevel.warning.rawValue))
                Text("Critical").tag(Double(HealthLevel.critical.rawValue))
            }
            .labelsHidden().fixedSize()
        case .thermalState:
            Picker("", selection: $rule.threshold) {
                Text("Fair").tag(Double(ThermalState.fair.rawValue))
                Text("Serious").tag(Double(ThermalState.serious.rawValue))
                Text("Critical").tag(Double(ThermalState.critical.rawValue))
            }
            .labelsHidden().fixedSize()
        default:
            TextField("", value: threshold, format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text(unitLabel).foregroundStyle(.secondary)
        }
    }

    /// The threshold as typed: a °F entry is stored to the nearest half °C (`storedCelsius`), which
    /// always reads back as the whole °F typed.
    private var threshold: Binding<Double> {
        guard rule.metric == .cpuTemperatureC, unit != .celsius else { return $rule.threshold }
        return Binding(get: { unit.threshold(fromCelsius: rule.threshold) },
                       set: { rule.threshold = unit.storedCelsius(entered: $0) })
    }

    private var unitLabel: String {
        switch rule.metric {
        case .cpuPercent, .packetLossPercent, .batteryPercent, .gpuPercent: "%"
        case .cpuTemperatureC: unit.symbol
        case .diskFreeGB: "GB"
        case .latencyMs: "ms"
        case .memoryPressure, .thermalState: ""
        }
    }
}

/// An alert event: severity, when (with its day, since the list spans a week), title and detail.
struct EventRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SeverityMark(level: event.severity, font: .caption2)
            Text(when)
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).fontWeight(.medium)
                if let detail = event.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        // Otherwise the mark, the clock and the text are read as three unrelated elements.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// "Today 14:02", or with the date and clock once it is older than yesterday.
    private var when: String {
        let calendar = Calendar.current
        let recent = calendar.isDateInToday(event.time) || calendar.isDateInYesterday(event.time)
        return recent ? Format.lastFired(event.time)
            : event.time.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private var spoken: String {
        [Format.health(event.severity), when, event.title, event.detail]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
