import Testing
@testable import PulseCore

@Suite struct HealthTests {
    @Test func thermalMapping() {
        #expect(ThermalState.nominal.health == .healthy)
        #expect(ThermalState.fair.health == .healthy)
        #expect(ThermalState.serious.health == .warning)
        #expect(ThermalState.critical.health == .critical)
    }

    @Test func memoryPressureMapping() {
        #expect(MemoryPressure.normal.health == .healthy)
        #expect(MemoryPressure.warning.health == .warning)
        #expect(MemoryPressure.critical.health == .critical)
    }

    @Test func worstPrefersKnownOverUnknown() {
        #expect(HealthLevel.unknown.worst(.healthy) == .healthy)
        #expect(HealthLevel.warning.worst(.critical) == .critical)
        #expect(HealthLevel.unknown.worst(.unknown) == .unknown)
    }

    @Test func thresholdBoundaries() {
        let t = Threshold(warning: 100, critical: 300)
        #expect(t.health(for: 99.9) == .healthy)
        #expect(t.health(for: 100) == .warning)
        #expect(t.health(for: 300) == .critical)
        #expect(t.health(for: nil) == .unknown)
        #expect(t.health(for: .nan) == .unknown)
    }

    @Test func networkHealthPRDDefaults() {
        let n = NetworkThresholds()
        #expect(n.health(connectivity: .online, latencyMs: 18, packetLossPercent: 0) == .healthy)
        #expect(n.health(connectivity: .online, latencyMs: 18, packetLossPercent: 2) == .warning)
        #expect(n.health(connectivity: .online, latencyMs: 320, packetLossPercent: 0) == .critical)
        #expect(n.health(connectivity: .offline, latencyMs: nil, packetLossPercent: nil) == .critical)
        #expect(n.health(connectivity: nil, latencyMs: 18, packetLossPercent: 0) == .unknown)
    }
}
