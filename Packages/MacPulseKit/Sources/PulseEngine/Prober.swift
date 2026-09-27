import Foundation
import PulseCore
import PulseCollectors
import PulseStore

public struct ProbeReading: Sendable, Equatable {
    public var address: String
    /// Nil when the latest probe timed out.
    public var latencyMs: Double?
    /// Over the last `LossWindow.capacity` probes.
    public var lossPercent: Double?
}

public struct DNSReading: Sendable, Equatable {
    public var server: String
    /// Nil when the resolver did not answer in time.
    public var latencyMs: Double?
}

public struct NetworkHealthReading: Sendable, Equatable {
    public var connectivity: Connectivity
    public var gateway: ProbeReading?
    /// The user's ping target (PRD §14); drives network health.
    public var internet: ProbeReading?
    /// A second public target (8.8.8.8, or 1.1.1.1 if that is the user's target), to tell a
    /// target-specific problem from a general upstream one.
    public var secondary: ProbeReading?
    public var dns: DNSReading?
    public var health: HealthLevel

    /// Pure: health from the primary internet target's latency/loss (PRD §7), Offline ⇒ Critical.
    static func make(connectivity: Connectivity, gateway: ProbeReading?, internet: ProbeReading?,
                     secondary: ProbeReading? = nil, dns: DNSReading? = nil,
                     thresholds: NetworkThresholds) -> NetworkHealthReading {
        let health = thresholds.health(connectivity: connectivity,
                                       latencyMs: internet?.latencyMs,
                                       packetLossPercent: internet?.lossPercent)
        return NetworkHealthReading(connectivity: connectivity, gateway: gateway, internet: internet,
                                    secondary: secondary, dns: dns, health: health)
    }
}

/// Active network probes on their own loop, so a timeout never delays the 1 s collectors.
actor Prober {
    private let interval: TimeInterval
    private var internetTarget: String
    private var thresholds: NetworkThresholds
    private var sequence: UInt16 = 0
    private var gatewayAddress: String?
    private var gatewayLoss = LossWindow()
    private var internetLoss = LossWindow()
    private var secondaryLoss = LossWindow()
    private var loop: Task<Void, Never>?
    private let recorder: HistoryRecorder?

    init(interval: TimeInterval = 5, internetTarget: String = "1.1.1.1", thresholds: NetworkThresholds = NetworkThresholds(),
         recorder: HistoryRecorder? = nil) {
        self.interval = interval
        self.recorder = recorder
        self.internetTarget = internetTarget
        self.thresholds = thresholds
    }

    func start(publish: @escaping @Sendable @MainActor (NetworkHealthReading) -> Void) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let reading = await self.probe()
                await self.recorder?.record(HistorySamples.from(reading, at: Date()))
                await publish(reading)
                let interval = self.interval
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    static func secondaryTarget(for primary: String) -> String {
        primary == "8.8.8.8" ? "1.1.1.1" : "8.8.8.8"
    }

    func configure(internetTarget: String, thresholds: NetworkThresholds) {
        if internetTarget != self.internetTarget {
            internetLoss = LossWindow()   // loss history belongs to the old target
        }
        self.internetTarget = internetTarget
        self.thresholds = thresholds
    }

    private func probe() async -> NetworkHealthReading {
        guard NetworkCollector.primaryInterface() != nil else {
            return .make(connectivity: .offline, gateway: nil, internet: nil, thresholds: thresholds)
        }
        let gateway = NetworkCollector.gatewayAddress()
        if gateway != gatewayAddress {
            gatewayAddress = gateway
            gatewayLoss = LossWindow()   // new network: old history no longer applies
        }
        sequence &+= 3
        let seq = sequence
        let target = internetTarget
        let secondTarget = Self.secondaryTarget(for: target)
        let resolver = DNSProbe.systemResolver()
        async let internetRTT = ICMPPing.ping(target, sequence: seq)
        async let secondaryRTT = ICMPPing.ping(secondTarget, sequence: seq &+ 1)
        async let gatewayRTT: Double? = gateway == nil ? nil : ICMPPing.ping(gateway!, sequence: seq &+ 2)
        async let dnsRTT: Double? = resolver == nil ? nil : DNSProbe.query(server: resolver!)
        let (internetResult, secondaryResult, gatewayResult, dnsResult) = await (internetRTT, secondaryRTT, gatewayRTT, dnsRTT)

        internetLoss.record(success: internetResult != nil)
        secondaryLoss.record(success: secondaryResult != nil)
        let internet = ProbeReading(address: target, latencyMs: internetResult, lossPercent: internetLoss.lossPercent)
        let secondary = ProbeReading(address: secondTarget, latencyMs: secondaryResult, lossPercent: secondaryLoss.lossPercent)
        var gatewayReading: ProbeReading?
        if let gateway {
            gatewayLoss.record(success: gatewayResult != nil)
            gatewayReading = ProbeReading(address: gateway, latencyMs: gatewayResult, lossPercent: gatewayLoss.lossPercent)
        }
        let dns = resolver.map { DNSReading(server: $0, latencyMs: dnsResult) }
        return .make(connectivity: .online, gateway: gatewayReading, internet: internet,
                     secondary: secondary, dns: dns, thresholds: thresholds)
    }
}
