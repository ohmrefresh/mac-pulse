import SwiftUI
import UserNotifications
import PulseCore
import PulseEngine

struct AlertsView: View {
    let metrics: LiveMetrics
    @Bindable var settings: AppSettings
    let notifier: AlertNotifier
    @State private var stored: [TimelineEvent] = []

    var body: some View {
        form
        .task { await notifier.refreshAuthorization() }
        .task { await loadStored() }
    }

    private var form: some View {
        Form {
            if notifier.authorization == .denied {
                Section {
                    Label("Notifications are turned off for Mac Pulse in System Settings. Alerts still appear in the timeline.",
                          systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach($settings.alertRules) { $rule in
                    RuleRow(rule: $rule, isFiring: metrics.firingAlertIDs.contains(rule.id),
                            onDelete: { settings.deleteRule(rule.id) })
                }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Menu("Add Rule") {
                        ForEach(AlertMetric.allCases, id: \.self) { metric in
                            Button(metric.displayName) { settings.addRule(for: metric) }
                        }
                    }
                    .fixedSize()
                }
            }
            Section("Recent alerts (7 days)") {
                if recentAlerts.isEmpty {
                    InlineEmpty("No alerts in the last 7 days.")
                } else {
                    ForEach(recentAlerts) { EventRow(event: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Stored alert events plus live ones not yet flushed, newest first.
    private var recentAlerts: [TimelineEvent] {
        let storedIDs = Set(stored.map(\.id))
        let live = metrics.recentEvents.filter { $0.category == .alert && !storedIDs.contains($0.id) }
        return Array((live + stored).sorted { $0.time > $1.time }.prefix(50))
    }

    private func loadStored() async {
        guard let history = metrics.history else { return }
        let from = Date().addingTimeInterval(-7 * 86_400)
        stored = (try? await Task.detached {
            try history.events(from: from, to: Date(), categories: [.alert], limit: 50)
        }.value) ?? []
    }
}

private struct RuleRow: View {
    @Binding var rule: AlertRule
    let isFiring: Bool
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $rule.isEnabled).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("\(rule.name) enabled")
                TextField("Name", text: $rule.name).font(.headline).textFieldStyle(.plain).labelsHidden()
                if isFiring { HealthBadge(level: rule.severity.health, label: "Firing") }
                Spacer()
                Picker("", selection: $rule.severity) {
                    Text("Warning").tag(AlertSeverity.warning)
                    Text("Critical").tag(AlertSeverity.critical)
                }
                .labelsHidden()
                .fixedSize()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete rule")
                    .confirmationDialog("Delete “\(rule.name)”?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive, action: onDelete)
                    }
            }
            HStack(spacing: 12) {
                Text(rule.metric.displayName).foregroundStyle(.secondary)
                Picker("", selection: $rule.comparator) {
                    Text(">").tag(AlertComparator.above)
                    Text("≥").tag(AlertComparator.atLeast)
                    Text("<").tag(AlertComparator.below)
                    Text("≤").tag(AlertComparator.atMost)
                }
                .labelsHidden()
                .fixedSize()
                thresholdEditor
                Text("for").foregroundStyle(.secondary)
                Stepper(rule.duration == 0 ? "immediately" : "\(Int(rule.duration)) s",
                        value: $rule.duration, in: 0...600, step: 5)
                    .monospacedDigit()
            }
            .disabled(!rule.isEnabled)
        }
        .padding(.vertical, 4)
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
            TextField("", value: $rule.threshold, format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private var unit: String {
        switch rule.metric {
        case .cpuPercent, .packetLossPercent, .batteryPercent, .gpuPercent: "%"
        case .cpuTemperatureC: "°C"
        case .diskFreeGB: "GB"
        case .latencyMs: "ms"
        case .memoryPressure, .thermalState: ""
        }
    }
}

struct EventRow: View {
    /// The most recent event of the run; its time is the row's time.
    let event: TimelineEvent
    /// How many consecutive identical events this row stands for, and when the run began. One
    /// occurrence reads as itself; a run reads as a count and a span, because "the same thing,
    /// still happening" is one fact, not eight.
    var repeats: Int = 1
    var runStarted: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SeverityMark(level: event.severity)
            Text(event.time, format: .dateTime.hour().minute().second())
                .monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        // Otherwise the mark, the clock and the text are read as three unrelated elements.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// A run replaces the single occurrence's detail: the last reading of eight is not the story,
    /// the repetition is.
    private var detail: String? {
        guard repeats > 1 else { return event.detail }
        guard let runStarted else { return "\(repeats) times" }
        return "\(repeats) times · \(runStarted.formatted(date: .omitted, time: .shortened))"
            + "–\(event.time.formatted(date: .omitted, time: .shortened))"
    }

    private var spoken: String {
        let time = event.time.formatted(date: .omitted, time: .standard)
        return [Format.health(event.severity), time, event.title, detail]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
