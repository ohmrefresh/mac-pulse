import SwiftUI
import PulseEngine

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            network.tabItem { Label("Network", systemImage: "network") }
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
            Text("Probes run every 5 seconds against the gateway and the ping host.")
                .font(.caption).foregroundStyle(.secondary)
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
        }
    }
}
