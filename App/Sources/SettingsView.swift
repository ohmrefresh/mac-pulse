import SwiftUI
import PulseCore
import PulseEngine
import PulseStore

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let metrics: LiveMetrics
    @State private var confirmClear = false
    @State private var clearMessage: String?
    @State private var previewVisible = false
    /// Shared with the Network page's "Edit targets", which opens this window on the Network tab.
    @AppStorage(Self.tabKey) private var tab = Tab.general.rawValue

    static let tabKey = "settingsTab"
    enum Tab: String { case general, menuBar, network, health, data }

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general.rawValue)
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }.tag(Tab.menuBar.rawValue)
            network.tabItem { Label("Network", systemImage: "network") }.tag(Tab.network.rawValue)
            health.tabItem { Label("Health", systemImage: "stethoscope") }.tag(Tab.health.rawValue)
            data.tabItem { Label("Data", systemImage: "externaldrive") }.tag(Tab.data.rawValue)
        }
        .frame(width: 460)
        .padding(20)
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                    set: { settings.launchAtLogin = $0 }))
            if let error = settings.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Toggle("Show Dock icon", isOn: $settings.showDockIcon)
            Picker("Temperature unit", selection: $settings.temperatureUnit) {
                ForEach(TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Sampling interval", selection: $settings.samplingInterval) {
                ForEach(AppSettings.samplingChoices, id: \.self) { Text("\(Int($0)) second\($0 == 1 ? "" : "s")").tag($0) }
            }
        }
    }

    private var menuBar: some View {
        Form {
            Toggle("Show icons", isOn: $settings.menuBarShowsIcons)
            Divider()
            ForEach(MenuBarItem.allCases, id: \.self) { item in
                Toggle(label(item), isOn: Binding(get: { settings.isEnabled(item) },
                                                  set: { settings.setEnabled(item, $0) }))
            }
            Text(menuBarPreview)
                .font(.caption).foregroundStyle(.secondary)
                .onAppear { previewVisible = true }
                .onDisappear { previewVisible = false }
        }
    }

    /// What the menu bar renders right now. Live readings are only read while this tab is on
    /// screen, so a closed Settings window cannot hold an observed dependency on them and
    /// re-render every tick — whether or not SwiftUI keeps the scene's view tree alive.
    private var menuBarPreview: String {
        guard previewVisible else { return "" }
        guard !settings.menuBarItems.isEmpty else { return "Shows the Mac Pulse icon only." }
        let inputs = metrics.menuBarInputs
        return "Shows: " + Format.menuBarSegments(MenuBarFormatter.segments(settings.menuBarItems, inputs),
                                                  cpuCelsius: inputs.cpuCelsius, unit: settings.temperatureUnit)
            .map(\.text).joined(separator: MenuBarFormatter.separator)
    }

    private var network: some View {
        Form {
            ProbeTargetsEditor(targets: $settings.probeTargets)
            Section("Thresholds (Primary target)") {
                LabeledContent("Latency warning") { pairedStepper($settings.latencyWarningMs, unit: "ms", step: 10, range: 10...5000, atMost: settings.latencyCriticalMs) }
                LabeledContent("Latency critical") { pairedStepper($settings.latencyCriticalMs, unit: "ms", step: 10, range: 10...5000, atLeast: settings.latencyWarningMs) }
                LabeledContent("Packet loss warning") { pairedStepper($settings.lossWarningPercent, unit: "%", step: 1, range: 1...100, atMost: settings.lossCriticalPercent) }
                LabeledContent("Packet loss critical") { pairedStepper($settings.lossCriticalPercent, unit: "%", step: 1, range: 1...100, atLeast: settings.lossWarningPercent) }
            }
            Section {
                Toggle("Look up public IP address", isOn: $settings.publicIPEnabled)
                Text("Asks 1.1.1.1 (Cloudflare) when the network changes and at most every 30 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Probes run every 5 seconds against the gateway and each target.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A minimum, not just an ideal: "Edit targets" switches to this tab programmatically, and
        // then the window only grows to satisfy a minimum.
        .frame(minHeight: 480)
    }

    private var health: some View {
        Form {
            Section("CPU health (timeline and diagnostics)") {
                LabeledContent("Warning at") { pairedStepper($settings.cpuWarningPercent, unit: "%", step: 5, range: 10...100, atMost: settings.cpuCriticalPercent) }
                LabeledContent("Critical at") { pairedStepper($settings.cpuCriticalPercent, unit: "%", step: 5, range: 10...100, atLeast: settings.cpuWarningPercent) }
            }
            Section("Diagnostics") {
                LabeledContent("Slow gateway") { stepper($settings.gatewayLatencyMs, unit: "ms", step: 10, range: 10...2000) }
                LabeledContent("Slow DNS") { stepper($settings.dnsSlowMs, unit: "ms", step: 10, range: 20...5000) }
                LabeledContent("Low disk below") { stepper($settings.lowDiskGB, unit: "GB", step: 5, range: 1...500) }
                LabeledContent("Hot CPU above") {
                    // Stored in °C; shown and stepped in the user's unit.
                    let unit = settings.temperatureUnit
                    stepper(Binding(get: { unit.threshold(fromCelsius: settings.hotCPUCelsius) },
                                    set: { settings.hotCPUCelsius = unit.storedCelsius(entered: $0) }),
                            unit: unit.symbol, step: 1,
                            range: unit.fromCelsius(60).rounded()...unit.fromCelsius(110).rounded())
                }
                Text("Internet latency and packet loss limits are on the Network tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var data: some View {
        Form {
            if settings.historyAvailable {
                if let error = settings.historyError {
                    Label("Saving history is failing: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Picker("Keep history for", selection: $settings.retention) {
                    ForEach(RetentionPreset.allCases, id: \.self) { Text(label($0)).tag($0) }
                }
                LabeledContent("Stored in") {
                    Text(HistoryStore.defaultURL().deletingLastPathComponent().path(percentEncoded: false))
                        .textSelection(.enabled).font(.caption)
                }
                Button("Clear History…", role: .destructive) { confirmClear = true }
                if let clearMessage { Text(clearMessage).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("History is unavailable: the database could not be opened. Live monitoring still works.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete all stored history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                Task { clearMessage = await settings.clearHistory() ?? "History cleared." }
            }
        } message: {
            Text("Charts, timeline and diagnostics lose everything recorded so far. This cannot be undone.")
        }
    }

    private func label(_ preset: RetentionPreset) -> String {
        switch preset {
        case .oneHour: "1 hour"
        case .sixHours: "6 hours"
        case .oneDay: "24 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    private func stepper(_ value: Binding<Double>, unit: String, step: Double, range: ClosedRange<Double>) -> some View {
        // One decimal only when there is one (a half-degree °C kept from a °F entry); never truncated.
        let v = value.wrappedValue
        return Stepper("\(Format.decimal(v, places: v.rounded() == v ? 0 : 1)) \(unit)", value: value, in: range, step: step)
            .monospacedDigit()
    }

    /// A warning stepper that cannot climb past its critical partner, and a critical stepper that
    /// cannot drop below its warning. The engine used to clamp `warning` silently, so Settings
    /// could show a pair it was not actually using.
    private func pairedStepper(_ value: Binding<Double>, unit: String, step: Double,
                               range: ClosedRange<Double>, atMost ceiling: Double) -> some View {
        stepper(value, unit: unit, step: step, range: range.lowerBound...Swift.min(ceiling, range.upperBound))
    }

    private func pairedStepper(_ value: Binding<Double>, unit: String, step: Double,
                               range: ClosedRange<Double>, atLeast floor: Double) -> some View {
        stepper(value, unit: unit, step: step, range: Swift.max(floor, range.lowerBound)...range.upperBound)
    }

    private func label(_ item: MenuBarItem) -> String {
        switch item {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network speed"
        case .latency: "Internet latency"
        case .battery: "Battery"
        case .thermal: "Thermal state"
        case .temperature: "CPU temperature (\(settings.temperatureUnit.symbol))"
        case .gpu: "GPU usage"
        }
    }
}
