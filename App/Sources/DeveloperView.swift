import SwiftUI
import PulseCore
import PulseCollectors
import PulseEngine

/// Phase 3: runtimes, Docker, listening ports, VPN/proxy and public IP. After mock_v2: runtime
/// tiles, then a card each for containers, ports and network setup.
struct DeveloperView: View {
    let metrics: LiveMetrics
    @Bindable var settings: AppSettings
    /// Dashboard toolbar search: filters containers and ports.
    let search: String
    @State private var containerScope = ContainerScope.running
    @State private var portScope = PortScope.yours
    private let currentUser = NSUserName()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                runtimes
                containers
                ports
                network
            }
            .padding(24)
        }
        .onAppear(perform: metrics.developerAppeared)
        .onDisappear(perform: metrics.developerDisappeared)
    }

    /// Ports once per process and port: netstat lists IPv4 and IPv6 separately.
    private var servicePorts: [ServicePort]? {
        metrics.developer.ports.map { ServicePort.merge($0, names: processNames) }
    }

    private var processNames: [Int32: String] {
        Dictionary(metrics.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Runtimes

    @ViewBuilder private var runtimes: some View {
        let summaries = RuntimeSummary.build(processes: metrics.processes, ports: servicePorts)
        if !summaries.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                ForEach(summaries, id: \.runtime) { RuntimeTile(summary: $0) }
            }
        }
    }

    // MARK: Containers

    private enum ContainerScope: Hashable { case running, all }

    @ViewBuilder private var containers: some View {
        if let all = metrics.developer.containers {
            let running = all.filter(\.isRunning)
            let stopped = all.count - running.count
            let scoped = (containerScope == .running ? running : all)
                .filter { DeveloperSearch.matches($0, search) }
                .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
            Section2(title: "Containers", subtitle: "\(running.count) running · \(stopped) stopped") {
                Picker("Show containers", selection: $containerScope) {
                    Text("Running").tag(ContainerScope.running)
                    Text("All \(all.count)").tag(ContainerScope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } content: {
                if scoped.isEmpty {
                    InlineEmpty(!search.isEmpty ? "No containers match “\(search)”."
                                : containerScope == .running ? "No containers running." : "No containers.")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ContainerColumns.header
                        Divider().padding(.bottom, 4)
                        ForEach(Array(scoped.enumerated()), id: \.element.id) { index, container in
                            ContainerRow(container: container, shaded: index.isMultiple(of: 2))
                        }
                    }
                }
                if containerScope == .running, stopped > 0 {
                    FooterNote(text: "\(stopped) stopped container\(stopped == 1 ? "" : "s")")
                }
            }
        } else {
            Section2(title: "Containers", subtitle: nil) {
                InlineEmpty("Docker isn't running — no daemon found (Docker Desktop, OrbStack or Colima).")
            }
        }
    }

    // MARK: Listening ports

    private enum PortScope: Hashable { case yours, all }

    @ViewBuilder private var ports: some View {
        if let all = servicePorts {
            let users = Dictionary(metrics.processes.compactMap { p in p.user.map { (p.pid, $0) } },
                                   uniquingKeysWith: { a, _ in a })
            let yours = all.filter { $0.isOwned(by: currentUser, users: users) }
            let inScope = portScope == .yours ? yours : all
            let exposed = inScope.filter { !$0.isLoopbackOnly }.count
            let shown = inScope.filter { DeveloperSearch.matches($0, search) }
            Section2(title: "Listening ports", subtitle: "\(inScope.count) TCP") {
                HStack(spacing: 10) {
                    if exposed > 0 {
                        // A fact about the Mac, not a Health Level: the section's tint, not Warning.
                        TintBadge(label: "\(exposed) exposed to the network", tint: MetricStyle.developer.tint)
                            .fixedSize()
                            .help("Listening on an address other machines can reach")
                    }
                    Picker("Show ports", selection: $portScope) {
                        Text("Yours").tag(PortScope.yours)
                        Text("All").tag(PortScope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } content: {
                if shown.isEmpty {
                    InlineEmpty(!search.isEmpty ? "No ports match “\(search)”."
                                : portScope == .yours ? "None of your processes are listening." : "Nothing is listening.")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        PortColumns.header
                        Divider().padding(.bottom, 4)
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, port in
                            PortRow(port: port, shaded: index.isMultiple(of: 2))
                        }
                    }
                }
                let hidden = all.count - yours.count
                if portScope == .yours, hidden > 0 {
                    FooterNote(text: "\(hidden) system port\(hidden == 1 ? "" : "s") hidden")
                }
            }
        } else {
            Section2(title: "Listening ports", subtitle: nil) {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Network

    private var network: some View {
        let config = metrics.developer.networkConfig
        return Section2(title: "Network setup", subtitle: nil) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("VPN").foregroundStyle(.secondary)
                    Text(config.map { $0.vpnActive ? "Connected (\($0.vpnInterfaces.joined(separator: ", ")))" : "Not connected" } ?? "Reading…")
                }
                GridRow {
                    Text("Proxy").foregroundStyle(.secondary)
                    if let proxies = config?.proxies, !proxies.isEmpty {
                        VStack(alignment: .leading) { ForEach(proxies, id: \.target) { Text("\($0.kind.rawValue): \($0.target)") } }
                    } else {
                        Text(config == nil ? "Reading…" : "None")
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
}

// MARK: - Pure helpers

/// A listening TCP port, once per process: netstat's IPv4 and IPv6 rows for the same socket merged.
struct ServicePort: Identifiable, Equatable {
    let port: UInt16
    let pid: Int32
    /// The process list's name for the PID, else netstat's (possibly truncated) one.
    let processName: String
    /// The widest address it listens on: "*", then a specific address, then loopback.
    let address: String
    let isLoopbackOnly: Bool

    var id: String { "\(pid)-\(port)" }
    var runtime: DevRuntime? { DevRuntime.detect(processName: processName) }

    /// "All interfaces", "This Mac only", or the one address it is bound to.
    var reachability: String {
        if isLoopbackOnly { return "This Mac only" }
        return address == "*" ? "All interfaces" : address
    }

    /// Ours when the owning process is the current user's. A PID not in the process list has no
    /// known owner, so it is not the user's.
    func isOwned(by user: String, users: [Int32: String]) -> Bool { users[pid] == user }

    /// Sorted by port, then PID.
    static func merge(_ ports: [ListeningPort], names: [Int32: String] = [:]) -> [ServicePort] {
        let groups = Dictionary(grouping: ports) { PortKey(pid: $0.pid, port: $0.port) }
        return groups.map { key, sockets in
            let wide = sockets.first { $0.address == "*" } ?? sockets.first { !$0.isLoopbackOnly } ?? sockets[0]
            return ServicePort(port: key.port, pid: key.pid,
                               processName: names[key.pid] ?? sockets[0].processName,
                               address: wide.address,
                               isLoopbackOnly: sockets.allSatisfy(\.isLoopbackOnly))
        }
        .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    private struct PortKey: Hashable {
        let pid: Int32
        let port: UInt16
    }
}

/// One runtime's processes right now, for its tile.
struct RuntimeSummary: Equatable {
    let runtime: DevRuntime
    let processCount: Int
    /// Ports its processes listen on; nil until ports have been read.
    let listening: Int?
    let cpuPercent: Double
    let memoryBytes: UInt64

    /// Only runtimes with a process running; busiest first.
    static func build(processes: [ProcessRow], ports: [ServicePort]?) -> [RuntimeSummary] {
        var byRuntime: [DevRuntime: [ProcessRow]] = [:]
        for process in processes {
            if let runtime = DevRuntime.detect(processName: process.name) { byRuntime[runtime, default: []].append(process) }
        }
        return byRuntime.map { runtime, rows in
            let pids = Set(rows.map(\.pid))
            return RuntimeSummary(runtime: runtime, processCount: rows.count,
                                  listening: ports.map { $0.filter { pids.contains($0.pid) }.count },
                                  cpuPercent: rows.reduce(0) { $0 + $1.cpuPercent },
                                  memoryBytes: rows.reduce(0) { $0 + $1.memoryBytes })
        }
        .sorted { ($0.cpuPercent, $1.runtime.rawValue) > ($1.cpuPercent, $0.runtime.rawValue) }
    }

    /// "3 processes · 1 listening"; the listening half waits for the first port read.
    var detail: String {
        let processes = "\(processCount) process\(processCount == 1 ? "" : "es")"
        return listening.map { "\(processes) · \($0) listening" } ?? processes
    }
}

/// The toolbar search on the Developer page.
enum DeveloperSearch {
    static func matches(_ container: DockerContainer, _ query: String) -> Bool {
        query.isEmpty || container.name.localizedCaseInsensitiveContains(query)
            || container.image.localizedCaseInsensitiveContains(query)
    }

    static func matches(_ port: ServicePort, _ query: String) -> Bool {
        query.isEmpty || String(port.port).contains(query) || String(port.pid) == query
            || port.processName.localizedCaseInsensitiveContains(query)
            || (port.runtime?.rawValue.localizedCaseInsensitiveContains(query) ?? false)
    }
}

// MARK: - Views

private struct RuntimeTile: View {
    let summary: RuntimeSummary

    var body: some View {
        let tint = MetricStyle.developer.tint
        HStack(spacing: 12) {
            Image(systemName: summary.runtime.symbol)
                .font(.title3)
                .foregroundStyle(tint.readableInk(on: .tintedFill(HealthBadge.fillOpacity), minimum: 3))
                .frame(width: 34, height: 34)
                .background(tint.opacity(HealthBadge.fillOpacity), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.runtime.rawValue).font(.headline).lineLimit(1)
                Text(summary.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            // The counts are what the tile is for; the figures on the right keep their width.
            .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Format.decimal(summary.cpuPercent, places: 1))%").font(.headline).monospacedDigit()
                Text(Format.memory(summary.memoryBytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .fixedSize()
        }
        .cardBackground(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

private enum ContainerColumns {
    static let dot: CGFloat = 8
    static let status: CGFloat = 190
    static let cpu: CGFloat = 60
    static let memory: CGFloat = 80
    static let spacing: CGFloat = 12

    static var header: some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: dot, height: 1)
            Text("Container").frame(maxWidth: .infinity, alignment: .leading)
            Text("Image").frame(maxWidth: .infinity, alignment: .leading)
            Text("Status").frame(width: status, alignment: .leading)
            Text("CPU").frame(width: cpu, alignment: .trailing)
            Text("Memory").frame(width: memory, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let shaded: Bool

    var body: some View {
        HStack(spacing: ContainerColumns.spacing) {
            // Filled means running, hollow means not: the state is carried by the shape, the family
            // by the tint. Green here would read as Healthy, and status colour belongs to Health Level.
            Group {
                if container.isRunning {
                    Circle().fill(MetricStyle.developer.tint.readableInk(on: .card, minimum: 3))
                } else {
                    Circle().strokeBorder(.secondary, lineWidth: 1)
                }
            }
            .frame(width: ContainerColumns.dot, height: ContainerColumns.dot)
            Text(container.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(container.image).font(.callout.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Docker's own healthcheck verdict is a health signal, so it takes the Healthy tint.
            Text(container.status)
                .foregroundStyle(container.status.contains("(healthy)")
                                 ? HealthLevel.healthy.tint.readableInk(on: .card, minimum: 4.5) : Color.secondary)
                .lineLimit(1)
                .frame(width: ContainerColumns.status, alignment: .leading)
            Text(container.cpuPercent.map { "\(Format.decimal($0, places: 1))%" } ?? "")
                .monospacedDigit()
                .frame(width: ContainerColumns.cpu, alignment: .trailing)
            Text(container.memoryBytes.map(Format.memory) ?? "")
                .monospacedDigit()
                .frame(width: ContainerColumns.memory, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(shaded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private enum PortColumns {
    static let port: CGFloat = 70
    static let reachable: CGFloat = 170
    static let pid: CGFloat = 70
    static let spacing: CGFloat = 12

    static var header: some View {
        HStack(spacing: spacing) {
            Text("Port").frame(width: port, alignment: .leading)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("Reachable from").frame(width: reachable, alignment: .leading)
            Text("PID").frame(width: pid, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }
}

private struct PortRow: View {
    let port: ServicePort
    let shaded: Bool

    var body: some View {
        HStack(spacing: PortColumns.spacing) {
            Text(String(port.port)).fontWeight(.semibold).monospacedDigit()
                .frame(width: PortColumns.port, alignment: .leading)
            HStack(spacing: 6) {
                Text(port.processName).lineLimit(1).truncationMode(.middle)
                if let runtime = port.runtime { RuntimeBadge(runtime: runtime) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Reachable from other machines is worth a second look, so it takes the section's tint;
            // status colour belongs to Health Levels, which a listening port does not have.
            DotLabel(text: port.reachability,
                     tint: port.isLoopbackOnly ? Color.secondary : MetricStyle.developer.tint,
                     ink: port.isLoopbackOnly ? Color.secondary : MetricStyle.developer.tint.readableInk(on: .card, minimum: 4.5))
                .frame(width: PortColumns.reachable, alignment: .leading)
            Text(String(port.pid)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: PortColumns.pid, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(shaded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A card's closing line: what the current scope leaves out.
private struct FooterNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RuntimeBadge: View {
    let runtime: DevRuntime
    var body: some View {
        let tint = MetricStyle.developer.tint
        Text(runtime.rawValue)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint.readableInk(on: .tintedFill(HealthBadge.fillOpacity), minimum: 4.5))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(HealthBadge.fillOpacity), in: Capsule())
            .fixedSize()
    }
}

private extension DevRuntime {
    /// Presentation only: every runtime shares the Developer tint.
    var symbol: String {
        switch self {
        case .docker: "shippingbox"
        case .kubernetes: "circle.hexagongrid"
        case .postgres, .mysql, .redis, .mongo: "cylinder.split.1x2"
        case .nginx: "server.rack"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}
