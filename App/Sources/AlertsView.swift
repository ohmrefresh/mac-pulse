import SwiftUI
import UserNotifications
import PulseCore
import PulseEngine

struct AlertsView: View {
    let metrics: LiveMetrics
    @Bindable var settings: AppSettings
    let notifier: AlertNotifier

    var body: some View {
        Form {
            if notifier.authorization == .denied {
                Section {
                    Label("Notifications are turned off for Mac Pulse in System Settings. Alerts still appear in the timeline.",
                          systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Rules") {
                ForEach($settings.alertRules) { $rule in
                    RuleRow(rule: $rule, isFiring: metrics.firingAlertIDs.contains(rule.id))
                }
            }
            Section("Recent alerts") {
                let recent = metrics.recentEvents.filter { $0.category == .alert }.suffix(20).reversed()
                if recent.isEmpty {
                    Text("No alerts since launch.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(recent)) { EventRow(event: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Alerts")
        .task { await notifier.refreshAuthorization() }
    }
}

private struct RuleRow: View {
    @Binding var rule: AlertRule
    let isFiring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $rule.isEnabled) { Text(rule.name).font(.headline) }
                    .toggleStyle(.switch)
                if isFiring { HealthBadge(level: rule.severity.health, label: "Firing") }
                Spacer()
                Picker("", selection: $rule.severity) {
                    Text("Warning").tag(AlertSeverity.warning)
                    Text("Critical").tag(AlertSeverity.critical)
                }
                .labelsHidden()
                .fixedSize()
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
        case .cpuPercent, .packetLossPercent, .batteryPercent: "%"
        case .diskFreeGB: "GB"
        case .latencyMs: "ms"
        case .memoryPressure, .thermalState: ""
        }
    }
}

struct EventRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(event.severity.tint).frame(width: 8, height: 8)
            Text(event.time, format: .dateTime.hour().minute().second())
                .monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                if let detail = event.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
