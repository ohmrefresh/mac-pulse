import SwiftUI
import PulseCollectors
import PulseEngine

/// Phase 3: Docker, local services, runtimes, VPN/proxy and public IP.
struct DeveloperView: View {
    let metrics: LiveMetrics
    @Bindable var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader("Developer", subtitle: "Docker, local services, runtimes and network setup.")
                docker
                services
                runtimes
                network
            }
            .padding(24)
        }
        .onAppear(perform: metrics.developerAppeared)
        .onDisappear(perform: metrics.developerDisappeared)
    }

    // MARK: Docker

    @ViewBuilder private var docker: some View {
        SubsectionHeader("Docker", subtitle: metrics.developer.containers.map { list in
            "\(list.filter(\.isRunning).count) running of \(list.count)"
        } ?? "Not running")
        if let containers = metrics.developer.containers {
            let rows = containers.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
            Table(rows) {
                TableColumn("Container") { c in
                    HStack(spacing: 6) {
                        Circle().fill(c.isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(c.name)
                    }
                }
                TableColumn("Image") { Text($0.image).foregroundStyle(.secondary).lineLimit(1) }
                TableColumn("Status") { Text($0.status).foregroundStyle(.secondary) }.width(140)
                TableColumn("CPU") { c in Text(c.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–").monospacedDigit() }.width(60)
                TableColumn("Memory") { c in Text(c.memoryBytes.map(Format.memory) ?? "–").monospacedDigit() }.width(80)
            }
            .frame(height: min(CGFloat(rows.count) * 26 + 32, 260))
        } else {
            Text("No Docker daemon found (Docker Desktop, OrbStack or Colima).").foregroundStyle(.secondary)
        }
    }

    // MARK: Local services

    @ViewBuilder private var services: some View {
        SubsectionHeader("Local services", subtitle: "Listening TCP ports")
        if let ports = metrics.developer.ports {
            let names = Dictionary(metrics.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
            Table(ports) {
                TableColumn("Port") { Text(String($0.port)).monospacedDigit() }.width(60)
                TableColumn("Reachable from") { p in
                    Text(p.isLoopbackOnly ? "This Mac only" : (p.address == "*" ? "All interfaces" : p.address))
                        .foregroundStyle(p.isLoopbackOnly ? .secondary : .primary)
                }.width(130)
                TableColumn("Process") { p in
                    let name = names[p.pid] ?? p.processName
                    HStack(spacing: 6) {
                        Text(name)
                        if let runtime = DevRuntime.detect(processName: name) { RuntimeBadge(runtime: runtime) }
                    }
                }
                TableColumn("PID") { Text(String($0.pid)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            }
            .frame(height: min(CGFloat(ports.count) * 26 + 32, 300))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Runtimes

    @ViewBuilder private var runtimes: some View {
        SubsectionHeader("Runtimes", subtitle: "Development processes running now")
        let groups = runtimeGroups
        if groups.isEmpty {
            Text("None detected.").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(groups, id: \.runtime) { g in
                    GridRow {
                        RuntimeBadge(runtime: g.runtime)
                        Text("\(g.processes.count) process\(g.processes.count == 1 ? "" : "es")").foregroundStyle(.secondary)
                        Text(String(format: "%.1f%% CPU", g.cpu)).monospacedDigit()
                        Text(Format.memory(g.processes.map(\.memoryBytes).reduce(0, +))).monospacedDigit()
                    }
                }
            }
        }
    }

    private struct RuntimeGroup {
        let runtime: DevRuntime
        let processes: [ProcessRow]
        var cpu: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    }

    private var runtimeGroups: [RuntimeGroup] {
        var byRuntime: [DevRuntime: [ProcessRow]] = [:]
        for process in metrics.processes {
            if let runtime = DevRuntime.detect(processName: process.name) { byRuntime[runtime, default: []].append(process) }
        }
        return byRuntime.map { RuntimeGroup(runtime: $0.key, processes: $0.value) }.sorted { $0.cpu > $1.cpu }
    }

    // MARK: Network

    @ViewBuilder private var network: some View {
        SubsectionHeader("Network setup", subtitle: nil)
        let config = metrics.developer.networkConfig
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Text("VPN").foregroundStyle(.secondary)
                Text(config.map { $0.vpnActive ? "Connected (\($0.vpnInterfaces.joined(separator: ", ")))" : "Not connected" } ?? "–")
            }
            GridRow {
                Text("Proxy").foregroundStyle(.secondary)
                if let proxies = config?.proxies, !proxies.isEmpty {
                    VStack(alignment: .leading) { ForEach(proxies, id: \.target) { Text("\($0.kind.rawValue): \($0.target)") } }
                } else {
                    Text(config == nil ? "–" : "None")
                }
            }
            GridRow {
                Text("Public IP").foregroundStyle(.secondary)
                HStack {
                    Toggle("Look up", isOn: $settings.publicIPEnabled).toggleStyle(.switch).labelsHidden()
                    if settings.publicIPEnabled {
                        Text(metrics.developer.publicIP.map { r in r.ip + (r.country.map { " · \($0)" } ?? "") } ?? "Looking up…")
                            .monospacedDigit().textSelection(.enabled)
                    } else {
                        Text("Off — asks 1.1.1.1 when enabled").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct RuntimeBadge: View {
    let runtime: DevRuntime
    var body: some View {
        Text(runtime.rawValue)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}
