import Foundation
import Testing
import PulseCore
import PulseCollectors
@testable import PulseEngine

@Suite struct TimelineGeneratorTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func cpu(_ percent: Double) -> Snapshot {
        var s = Snapshot()
        s.cpu = CPUReading(totalPercent: percent, perCorePercent: [percent])
        return s
    }

    func processes(_ rows: [ProcessRow]) -> Snapshot {
        var s = Snapshot()
        s.processes = rows
        return s
    }

    func row(_ pid: Int32, _ name: String, cpu: Double = 0, mem: UInt64 = 0) -> ProcessRow {
        ProcessRow(pid: pid, name: name, cpuPercent: cpu, memoryBytes: mem, isPrivileged: false)
    }

    func online(_ ms: Double?, loss: Double = 0) -> NetworkHealthReading {
        .make(connectivity: .online, gateway: nil,
              internet: ProbeReading(address: "1.1.1.1", latencyMs: ms, lossPercent: loss), thresholds: NetworkThresholds())
    }

    @Test func firstObservationIsSilentBaseline() {
        var g = TimelineGenerator()
        #expect(g.observe(cpu(95), at: at(0)).isEmpty)
    }

    @Test func healthChangeNeedsTenSecondHold() {
        var g = TimelineGenerator()
        _ = g.observe(cpu(10), at: at(0))
        #expect(g.observe(cpu(85), at: at(1)).isEmpty)
        #expect(g.observe(cpu(85), at: at(10)).isEmpty)          // held 9 s
        let e = g.observe(cpu(86), at: at(11))
        #expect(e.map(\.title) == ["CPU → Warning"])
        #expect(e.first?.detail == "86%")
        #expect(g.observe(cpu(86), at: at(12)).isEmpty)          // reported once
    }

    @Test func blipDoesNotLog() {
        var g = TimelineGenerator()
        _ = g.observe(cpu(10), at: at(0))
        _ = g.observe(cpu(85), at: at(1))
        _ = g.observe(cpu(10), at: at(5))                       // back before 10 s
        #expect(g.observe(cpu(10), at: at(30)).isEmpty)
    }

    @Test func recoveryLogsBackToNormal() {
        var g = TimelineGenerator()
        _ = g.observe(cpu(10), at: at(0))
        _ = g.observe(cpu(85), at: at(1))
        _ = g.observe(cpu(85), at: at(11))
        _ = g.observe(cpu(20), at: at(12))
        #expect(g.observe(cpu(20), at: at(22)).map(\.title) == ["CPU back to normal"])
    }

    @Test func thermalAndPowerChangesLogImmediately() {
        var g = TimelineGenerator()
        var s = Snapshot()
        s.thermal = .nominal
        s.battery = BatteryReading(percent: 80, isCharging: false, onACPower: true, minutesRemaining: nil,
                                   cycleCount: nil, maximumCapacityPercent: nil)
        #expect(g.observe(s, at: at(0)).isEmpty)
        s.thermal = .serious
        s.battery?.onACPower = false
        let e = g.observe(s, at: at(1))
        #expect(Set(e.map(\.title)) == ["Thermal Nominal → Serious", "Switched to battery power"])
        #expect(e.first { $0.category == .thermal }?.severity == .warning)
    }

    @Test func connectivityAndVPNTransitions() {
        var g = TimelineGenerator()
        #expect(g.observe(online(10), interface: "en0", at: at(0)).isEmpty)
        let vpn = g.observe(online(10), interface: "utun4", at: at(5))
        #expect(vpn.map(\.title) == ["VPN connected"])
        #expect(vpn.first?.detail == "en0 → utun4")
        let offline = NetworkHealthReading.make(connectivity: .offline, gateway: nil, internet: nil, thresholds: NetworkThresholds())
        #expect(g.observe(offline, interface: nil, at: at(10)).map(\.title) == ["Offline"])
        #expect(g.observe(online(10), interface: "en0", at: at(15)).map(\.title) == ["Back online", "VPN disconnected"])
    }

    @Test func networkDegradationDebounced() {
        var g = TimelineGenerator()
        _ = g.observe(online(18), interface: "en0", at: at(0))
        #expect(g.observe(online(240), interface: "en0", at: at(5)).isEmpty)
        let e = g.observe(online(250), interface: "en0", at: at(15))
        #expect(e.map(\.title) == ["Network → Warning"])
        #expect(e.first?.detail == "latency 250 ms, loss 0%")
    }

    @Test func processHogAnnouncedOnceAfterHold() {
        var g = TimelineGenerator()
        let calm = [row(1, "Finder", cpu: 1)]
        _ = g.observe(processes(calm + [row(2, "Docker", cpu: 48)]), at: at(0))
        #expect(g.observe(processes(calm + [row(2, "Docker", cpu: 50)]), at: at(5)).isEmpty)
        let e = g.observe(processes(calm + [row(2, "Docker", cpu: 52)]), at: at(10))
        #expect(e.map(\.title) == ["Docker CPU increased"])
        #expect(g.observe(processes(calm + [row(2, "Docker", cpu: 60)]), at: at(15)).isEmpty)
        // Drops out, comes back: announced again after a fresh hold.
        _ = g.observe(processes(calm + [row(2, "Docker", cpu: 5)]), at: at(20))
        _ = g.observe(processes(calm + [row(2, "Docker", cpu: 60)]), at: at(25))
        #expect(g.observe(processes(calm + [row(2, "Docker", cpu: 60)]), at: at(35)).map(\.title) == ["Docker CPU increased"])
    }

    @Test func memoryGrowthWithinWindow() {
        var g = TimelineGenerator()
        let gb: UInt64 = 1 << 30
        _ = g.observe(processes([row(7, "Xcode", mem: gb / 2)]), at: at(0))
        #expect(g.observe(processes([row(7, "Xcode", mem: 2 * gb)]), at: at(60)).isEmpty)       // +1.5 GB
        let e = g.observe(processes([row(7, "Xcode", mem: 3 * gb)]), at: at(120))               // +2.5 GB
        #expect(e.map(\.title) == ["Xcode memory grew"])
        #expect(e.first?.detail == "+2.5 GB in under 5 min")
        #expect(g.observe(processes([row(7, "Xcode", mem: 4 * gb)]), at: at(180)).isEmpty)      // not repeated
    }

    @Test func slowMemoryGrowthOutsideWindowIgnored() {
        var g = TimelineGenerator()
        let gb: UInt64 = 1 << 30
        _ = g.observe(processes([row(7, "Xcode", mem: gb)]), at: at(0))
        _ = g.observe(processes([row(7, "Xcode", mem: 2 * gb)]), at: at(200))
        #expect(g.observe(processes([row(7, "Xcode", mem: 3 * gb + gb / 2)]), at: at(400)).isEmpty)  // low in window is 2 GB
    }
}
