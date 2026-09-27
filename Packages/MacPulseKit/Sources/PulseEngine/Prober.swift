import Foundation
import PulseCore
import PulseCollectors

public struct ProbeReading: Sendable, Equatable {
    public var address: String
    /// Nil when the latest probe timed out.
    public var latencyMs: Double?
    /// Over the last `LossWindow.capacity` probes.
    public var lossPercent: Double?
}

public struct NetworkHealthReading: Sendable, Equatable {
    public var connectivity: Connectivity
    public var gateway: ProbeReading?
    public var internet: ProbeReading?
    public var health: HealthLevel

    /// Pure: health from internet latency/loss (PRD §7), Offline ⇒ Critical.
    static func make(connectivity: Connectivity, gateway: ProbeReading?, internet: ProbeReading?,
                     thresholds: NetworkThresholds) -> NetworkHealthReading {
        let health = thresholds.health(connectivity: connectivity,
                                       latencyMs: internet?.latencyMs,
                                       packetLossPercent: internet?.lossPercent)
        return NetworkHealthReading(connectivity: connectivity, gateway: gateway, internet: internet, health: health)
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
    private var loop: Task<Void, Never>?

    init(interval: TimeInterval = 5, internetTarget: String = "1.1.1.1", thresholds: NetworkThresholds = NetworkThresholds()) {
        self.interval = interval
        self.internetTarget = internetTarget
        self.thresholds = thresholds
    }

    func start(publish: @escaping @Sendable @MainActor (NetworkHealthReading) -> Void) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let reading = await self.probe()
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
        sequence &+= 2
        let seq = sequence
        let target = internetTarget
        async let internetRTT = ICMPPing.ping(target, sequence: seq)
        async let gatewayRTT: Double? = gateway == nil ? nil : ICMPPing.ping(gateway!, sequence: seq &+ 1)
        let (internetResult, gatewayResult) = await (internetRTT, gatewayRTT)

        internetLoss.record(success: internetResult != nil)
        let internet = ProbeReading(address: target, latencyMs: internetResult, lossPercent: internetLoss.lossPercent)
        var gatewayReading: ProbeReading?
        if let gateway {
            gatewayLoss.record(success: gatewayResult != nil)
            gatewayReading = ProbeReading(address: gateway, latencyMs: gatewayResult, lossPercent: gatewayLoss.lossPercent)
        }
        return .make(connectivity: .online, gateway: gatewayReading, internet: internet, thresholds: thresholds)
    }
}
