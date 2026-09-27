import Foundation
import IOKit.ps
import Testing
@testable import PulseCollectors
import PulseCore

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

    @Test func condition() throws {
        #expect(try #require(BatteryCollector.parse(description())).condition == nil)
        var d = description()
        d[kIOPSBatteryHealthKey] = kIOPSGoodValue
        #expect(try #require(BatteryCollector.parse(d)).condition == .normal)
        d[kIOPSBatteryHealthKey] = kIOPSFairValue
        #expect(try #require(BatteryCollector.parse(d)).condition == .serviceRecommended)
        d[kIOPSBatteryHealthKey] = kIOPSGoodValue
        d[kIOPSBatteryHealthConditionKey] = "Check Battery"
        #expect(try #require(BatteryCollector.parse(d)).condition?.health == .warning)
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

@Suite struct SystemInfoTests {
    @Test func loadAverageRejectsShortOrImplausibleReads() {
        #expect(LoadAverage(raw: [1, 2]) == nil)
        #expect(LoadAverage(raw: [1, -2, 3]) == nil)
        #expect(LoadAverage(raw: [1, 2, .nan]) == nil)
        #expect(LoadAverage(raw: [1.5, 2, 3])?.oneMinute == 1.5)
    }

    @Test func liveLoadAverageIsPlausible() throws {
        let load = try #require(SystemInfoCollector.loadAverage())
        // A run queue longer than 512 on a test host means we read garbage, not a busy Mac.
        #expect(load.oneMinute >= 0 && load.oneMinute < 512)
        #expect(load.fifteenMinutes >= 0)
    }

    @Test func liveTopologyMatchesCoreCount() throws {
        let topology = SystemInfoCollector.topology()
        let logical = try #require(topology.logicalCount)
        #expect(logical == ProcessInfo.processInfo.processorCount)
        #expect(topology.physicalCount.map { $0 <= logical } ?? true)
        // Apple Silicon splits the cores into named clusters; Intel reports none at all.
        if !topology.clusters.isEmpty {
            #expect(topology.clusters.reduce(0) { $0 + $1.logicalCount } == logical)
            #expect(topology.clusters.allSatisfy { !$0.name.isEmpty && $0.logicalCount > 0 })
        }
    }

    @Test func liveBootTimeIsInThePast() throws {
        let boot = try #require(SystemInfoCollector.bootTime())
        let uptime = Date().timeIntervalSince(boot)
        #expect(uptime > 0)
        #expect(abs(uptime - ProcessInfo.processInfo.systemUptime) < 86_400)   // sleep time aside, same ballpark
    }
}

@Suite struct MemoryCompositionTests {
    private let pages = MemoryCollector.PageCounts(internalPages: 100, purgeable: 20, wired: 30,
                                                  compressor: 10, external: 40)

    @Test func activityMonitorSplit() {
        let r = MemoryCollector.reading(pages: pages, pageSize: 1_000, totalBytes: 300_000,
                                        swapUsedBytes: 5_000, pressure: nil)
        #expect(r.appBytes == 80_000)            // internal − purgeable
        #expect(r.cachedFilesBytes == 60_000)    // external + purgeable
        #expect(r.usedBytes == 120_000)          // app + wired + compressed, swap excluded
    }

    @Test func ringSlicesSumToInstalledMemory() {
        let r = MemoryCollector.reading(pages: pages, pageSize: 1_000, totalBytes: 300_000,
                                        swapUsedBytes: 5_000, pressure: nil)
        #expect(r.usedBytes + r.cachedFilesBytes + r.freeBytes == r.totalBytes)
    }

    @Test func freeNeverUnderflowsWhenAccountingExceedsTotal() {
        let r = MemoryCollector.reading(pages: pages, pageSize: 1_000, totalBytes: 100_000,
                                        swapUsedBytes: 0, pressure: nil)
        #expect(r.freeBytes == 0)
    }
}
