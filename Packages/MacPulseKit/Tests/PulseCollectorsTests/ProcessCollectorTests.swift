import Foundation
import Testing
@testable import PulseCollectors

@Suite struct CPUTimeTrackerTests {
    @Test func percentOfOneCore() {
        var t = CPUTimeTracker<UInt64>()
        #expect(t.percent(pid: 10, identity: 1, cpuNanos: 0, at: 0) == nil)
        // 1.5 s of CPU over 1 s wall = 150% (1.5 cores).
        #expect(t.percent(pid: 10, identity: 1, cpuNanos: 1_500_000_000, at: 1) == 150)
    }

    @Test func reusedPIDStartsFresh() {
        var t = CPUTimeTracker<UInt64>()
        _ = t.percent(pid: 10, identity: 1, cpuNanos: 5_000_000_000, at: 0)
        #expect(t.percent(pid: 10, identity: 2, cpuNanos: 100, at: 1) == nil)
        #expect(t.percent(pid: 10, identity: 2, cpuNanos: 100 + 250_000_000, at: 2) == 25)
    }

    @Test func forgottenPIDHasNoBaseline() {
        var t = CPUTimeTracker<UInt64>()
        _ = t.percent(pid: 10, identity: 1, cpuNanos: 0, at: 0)
        t.forgetAll(except: [])
        #expect(t.percent(pid: 10, identity: 1, cpuNanos: 1_000, at: 1) == nil)
    }
}

@Suite struct PSParserTests {
    @Test func cpuTimeFormats() {
        #expect(PSParser.cpuNanos("0:05.27") == 5_270_000_000)
        #expect(PSParser.cpuNanos("123:45.50") == UInt64((123 * 60 + 45.5) * 1e9))
        #expect(PSParser.cpuNanos("1:02:03") == UInt64((3600 + 2 * 60 + 3) * 1e9))
        #expect(PSParser.cpuNanos("2-01:00:00") == UInt64((2 * 86_400 + 3600) * 1e9))
        #expect(PSParser.cpuNanos("garbage") == nil)
    }

    @Test func parsesLinesWithSpacesInCommand() {
        let output = """
            1     0  2-03:04:05   1:45.55  22992 launchd
          400    88     10:00   0:10.00   4096 WindowServer
          999   501     00:07   0:00.01    100 Some App
        bad line
        """
        let entries = PSParser.parse(output)
        #expect(entries.map(\.pid) == [1, 400, 999])
        #expect(entries[1].name == "WindowServer" && entries[1].uid == 88)
        #expect(entries[1].residentBytes == 4096 * 1024)
        #expect(entries[2].name == "Some App")
        #expect(entries[0].elapsedNanos == UInt64((2 * 86_400 + 3 * 3600 + 4 * 60 + 5) * 1e9))
    }
}

@Suite struct ProcessCollectorLiveTests {
    @Test func seesPrivilegedProcessesAndOwnProcess() throws {
        var collector = ProcessCollector()
        let rows = collector.sample(refreshPrivileged: true)
        let own = try #require(rows.first { $0.pid == getpid() })
        #expect(!own.isPrivileged)
        #expect(own.memoryBytes > 0)
        // launchd (pid 1) is root-owned: only visible through the ps path.
        let launchd = try #require(rows.first { $0.pid == 1 })
        #expect(launchd.isPrivileged)
        #expect(launchd.name == "launchd")
        #expect(launchd.user == "root")
        #expect(own.user == NSUserName())
        let started = try #require(own.startTime)
        #expect(started <= Date() && Date().timeIntervalSince(started) < 3_600)
        #expect(try #require(launchd.startTime) < started)
        #expect(Set(rows.map(\.pid)).count == rows.count, "no duplicate PIDs")
    }

    @Test func secondSampleReportsCPU() {
        var collector = ProcessCollector()
        _ = collector.sample(refreshPrivileged: false)
        var x = 0.0
        for i in 0..<3_000_000 { x += Double(i).squareRoot() }   // burn CPU in this process
        let rows = collector.sample(refreshPrivileged: false)
        #expect(x > 0)
        #expect((rows.first { $0.pid == getpid() }?.cpuPercent ?? 0) > 0)
    }
}
