import SwiftUI
import PulseEngine
import PulseStore

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var confirmClear = false
    @State private var clearMessage: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            network.tabItem { Label("Network", systemImage: "network") }
            health.tabItem { Label("Health", systemImage: "stethoscope") }
            data.tabItem { Label("Data", systemImage: "externaldrive") }
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
            Picker("Sampling interval", selection: $settings.samplingInterval) {
                ForEach(AppSettings.samplingChoices, id: \.self) { Text("\(Int($0)) second\($0 == 1 ? "" : "s")").tag($0) }
            }
        }
    }

    private var menuBar: some View {
        Form {
            ForEach(MenuBarItem.allCases, id: \.self) { item in
                Toggle(label(item), isOn: Binding(get: { settings.isEnabled(item) },
                                                  set: { settings.setEnabled(item, $0) }))
            }
            Text("Reserves room for: " + MenuBarFormatter.widestText(settings.menuBarItems))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var network: some View {
        Form {
            TextField("Ping host (IPv4)", text: $settings.pingTarget)
            if !settings.pingTargetIsValid {
                Text("Enter an IPv4 address, e.g. 1.1.1.1. Still probing the last valid host.")
                    .font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Latency warning") { stepper($settings.latencyWarningMs, unit: "ms", step: 10, range: 10...5000) }
            LabeledContent("Latency critical") { stepper($settings.latencyCriticalMs, unit: "ms", step: 10, range: 10...5000) }
            LabeledContent("Packet loss warning") { stepper($settings.lossWarningPercent, unit: "%", step: 1, range: 1...100) }
            LabeledContent("Packet loss critical") { stepper($settings.lossCriticalPercent, unit: "%", step: 1, range: 1...100) }
            Toggle("Look up public IP address", isOn: $settings.publicIPEnabled)
            Text("Asks 1.1.1.1 (Cloudflare) when the network changes and at most every 30 minutes.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Probes run every 5 seconds against the gateway and the ping host.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var health: some View {
        Form {
            Section("CPU health (timeline and diagnostics)") {
                LabeledContent("Warning at") { stepper($settings.cpuWarningPercent, unit: "%", step: 5, range: 10...100) }
                LabeledContent("Critical at") { stepper($settings.cpuCriticalPercent, unit: "%", step: 5, range: 10...100) }
            }
            Section("Diagnostics") {
                LabeledContent("Slow gateway") { stepper($settings.gatewayLatencyMs, unit: "ms", step: 10, range: 10...2000) }
                LabeledContent("Slow DNS") { stepper($settings.dnsSlowMs, unit: "ms", step: 10, range: 20...5000) }
                LabeledContent("Low disk below") { stepper($settings.lowDiskGB, unit: "GB", step: 5, range: 1...500) }
                LabeledContent("Hot CPU above") { stepper($settings.hotCPUCelsius, unit: "°C", step: 1, range: 60...110) }
                Text("Internet latency and packet loss limits are on the Network tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var data: some View {
        Form {
            if settings.historyAvailable {
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
        Stepper("\(Int(value.wrappedValue)) \(unit)", value: value, in: range, step: step).monospacedDigit()
    }

    private func label(_ item: MenuBarItem) -> String {
        switch item {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network speed"
        case .latency: "Internet latency"
        case .battery: "Battery"
        case .thermal: "Thermal state"
        case .temperature: "CPU temperature (°C)"
        case .gpu: "GPU usage"
        }
    }
}
