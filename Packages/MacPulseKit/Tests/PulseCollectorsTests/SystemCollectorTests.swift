import Foundation
import IOKit.ps
import Testing
@testable import PulseCollectors

@Suite struct NetworkRateTests {
    private func counters(_ name: String = "en0", rx: UInt64, tx: UInt64) -> InterfaceCounters {
        InterfaceCounters(name: name, receivedBytes: rx, sentBytes: tx)
    }

    @Test func bytesPerSecond() throws {
        let r = try #require(NetworkRate.reading(from: counters(rx: 1_000, tx: 500), at: 10,
                                                 to: counters(rx: 9_000, tx: 1_500), at: 12))
        #expect(r.downBytesPerSec == 4_000)
        #expect(r.upBytesPerSec == 500)
        #expect(r.interface == "en0")
    }

    @Test func interfaceChangeOrResetOrNoTimeIsNil() {
        #expect(NetworkRate.reading(from: counters(rx: 0, tx: 0), at: 0, to: counters("en1", rx: 10, tx: 10), at: 1) == nil)
        #expect(NetworkRate.reading(from: counters(rx: 100, tx: 0), at: 0, to: counters(rx: 10, tx: 0), at: 1) == nil)
        #expect(NetworkRate.reading(from: counters(rx: 0, tx: 0), at: 5, to: counters(rx: 10, tx: 0), at: 5) == nil)
    }

    @Test func liveCountersIncludePrimaryInterface() throws {
        let primary = try #require(NetworkCollector.primaryInterface(), "test host has no network route")
        #expect(NetworkCollector.counters()[primary] != nil)
        #expect(Array(NetworkCollector.counters(only: primary).keys) == [primary])
        #expect(NetworkCollector.counters(only: "nonexistent0").isEmpty)
    }
}

@Suite struct BatteryParseTests {
    private func description(current: Int = 87, charging: Bool = false, state: String = kIOPSBatteryPowerValue,
                             toEmpty: Int = 222, toFull: Int = -1) -> [String: Any] {
        [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: 100,
         kIOPSIsChargingKey: charging, kIOPSPowerSourceStateKey: state,
         kIOPSTimeToEmptyKey: toEmpty, kIOPSTimeToFullChargeKey: toFull]
    }

    @Test func discharging() throws {
        let r = try #require(BatteryCollector.parse(description()))
        #expect(r.percent == 87)
        #expect(!r.isCharging && !r.onACPower)
        #expect(r.minutesRemaining == 222)
    }

    @Test func chargingUsesTimeToFull() throws {
        let r = try #require(BatteryCollector.parse(description(charging: true, state: kIOPSACPowerValue, toFull: 40)))
        #expect(r.minutesRemaining == 40)
    }

    @Test func stillEstimatingIsNil() throws {
        #expect(try #require(BatteryCollector.parse(description(toEmpty: -1))).minutesRemaining == nil)
    }

    @Test func pluggedInNotChargingHasNoEstimate() throws {
        #expect(try #require(BatteryCollector.parse(description(state: kIOPSACPowerValue))).minutesRemaining == nil)
    }

    @Test func ignoresNonInternalSources() {
        var d = description()
        d[kIOPSTypeKey] = "UPS"
        #expect(BatteryCollector.parse(d) == nil)
    }
}

@Suite struct ThermalAndDiskTests {
    @Test func thermalMapping() {
        #expect(ThermalCollector.map(.nominal) == .nominal)
        #expect(ThermalCollector.map(.fair) == .fair)
        #expect(ThermalCollector.map(.serious) == .serious)
        #expect(ThermalCollector.map(.critical) == .critical)
    }

    @Test func liveDiskIsPlausible() throws {
        let r = try #require(DiskCollector().sample())
        #expect(r.totalBytes > 0)
        #expect(r.availableBytes > 0 && r.availableBytes <= r.totalBytes)
    }
}
