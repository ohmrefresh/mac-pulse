import Foundation
import PulseCore
import PulseCollectors

/// Phase 3 developer data: Docker, listening ports, VPN/proxy, public IP.
public struct DeveloperSnapshot: Sendable, Equatable {
    /// Nil when no Docker socket exists or the daemon did not answer.
    public var containers: [DockerContainer]?
    /// Only collected while the Developer view is visible.
    public var ports: [ListeningPort]?
    public var networkConfig: NetworkConfigReading?
    public var publicIP: PublicIPLookup.Result?

    public init(containers: [DockerContainer]? = nil, ports: [ListeningPort]? = nil,
                networkConfig: NetworkConfigReading? = nil, publicIP: PublicIPLookup.Result? = nil) {
        self.containers = containers
        self.ports = ports
        self.networkConfig = networkConfig
        self.publicIP = publicIP
    }
}

/// Own 5 s loop (decision D3): container list every 30 s in the background, full stats and ports
/// every 5 s only while visible. Public IP only when enabled (D1): on network change or every 30 min.
actor DeveloperMonitor {
    static let tick: TimeInterval = 5
    static let backgroundInterval: TimeInterval = 30
    static let publicIPInterval: TimeInterval = 1_800

    private var visible = false
    private var publicIPEnabled = false
    private var snapshot = DeveloperSnapshot()
    private var tracker = DockerStatsTracker()
    private var lastContainers: Date = .distantPast
    private var lastConfig: Date = .distantPast
    private var lastPublicIP: Date = .distantPast
    private var lastNetworkKey: String?
    private var loop: Task<Void, Never>?

    func start(publish: @escaping @Sendable @MainActor (DeveloperSnapshot) -> Void) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.refresh(now: Date())
                await publish(snapshot)
                try? await Task.sleep(for: .seconds(Self.tick), tolerance: .seconds(1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value { lastContainers = .distantPast; lastConfig = .distantPast }   // refresh immediately
        if !value { snapshot.ports = nil }
    }

    func setPublicIPEnabled(_ value: Bool) {
        publicIPEnabled = value
        if value { lastPublicIP = .distantPast } else { snapshot.publicIP = nil }
    }

    private func refresh(now: Date) async -> DeveloperSnapshot {
        if visible || now.timeIntervalSince(lastContainers) >= Self.backgroundInterval {
            lastContainers = now
            if let socket = DockerClient.socketPath(), let list = DockerClient.containers(socket: socket) {
                snapshot.containers = visible ? tracker.annotate(list, socket: socket) : list
            } else {
                snapshot.containers = nil
            }
        }
        if visible {
            snapshot.ports = ListeningPortsCollector.sample()
        }
        if visible || now.timeIntervalSince(lastConfig) >= Self.backgroundInterval {
            lastConfig = now
            snapshot.networkConfig = NetworkConfigCollector.sample()
        }
        if publicIPEnabled, let config = snapshot.networkConfig {
            let key = "\(config.primaryInterface ?? "-")|\(config.vpnInterfaces.joined(separator: ","))"
            if key != lastNetworkKey || now.timeIntervalSince(lastPublicIP) >= Self.publicIPInterval {
                lastNetworkKey = key
                lastPublicIP = now
                snapshot.publicIP = config.primaryInterface == nil ? nil : await PublicIPLookup.fetch()
            }
        }
        return snapshot
    }

    /// Timeline events for containers that started or stopped between two lists.
    static func containerEvents(old: [DockerContainer]?, new: [DockerContainer]?, at now: Date) -> [TimelineEvent] {
        guard let old, let new else { return [] }
        let wasRunning = Dictionary(old.map { ($0.id, $0.isRunning) }, uniquingKeysWith: { a, _ in a })
        return new.compactMap { c in
            let before = wasRunning[c.id] ?? false
            guard before != c.isRunning else { return nil }
            return TimelineEvent(time: now, category: .process, severity: .healthy,
                                 title: c.isRunning ? "Container \(c.name) started" : "Container \(c.name) stopped",
                                 detail: c.image)
        }
    }
}
