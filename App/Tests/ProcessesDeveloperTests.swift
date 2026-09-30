import Foundation
import Testing
import PulseCollectors
@testable import MacPulse

/// Pure helpers behind the Processes and Developer pages.
@Suite struct ProcessesDeveloperTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func runningKeepsTwoUnits() {
        #expect(Format.running(since: now.addingTimeInterval(-(86_400 + 23 * 3_600 + 59 * 60)), now: now) == "1d 23h")
        #expect(Format.running(since: now.addingTimeInterval(-(12 * 3_600 + 37 * 60 + 5)), now: now) == "12h 37m")
        #expect(Format.running(since: now.addingTimeInterval(-3_600), now: now) == "1h 0m")
        #expect(Format.running(since: now.addingTimeInterval(-150), now: now) == "2m")
        #expect(Format.running(since: now.addingTimeInterval(-59), now: now) == "<1m")
        // A start ahead of now (clock change) is just started, never negative.
        #expect(Format.running(since: now.addingTimeInterval(30), now: now) == "<1m")
    }

    @Test func scopeSplitsByOwner() {
        let mine = ProcessRow(pid: 1, name: "Finder", cpuPercent: 0, memoryBytes: 0, isPrivileged: false, user: "me")
        let root = ProcessRow(pid: 2, name: "launchd", cpuPercent: 0, memoryBytes: 0, isPrivileged: true, user: "root")
        let unknown = ProcessRow(pid: 3, name: "?", cpuPercent: 0, memoryBytes: 0, isPrivileged: false, user: nil)
        let rows = [mine, root, unknown]
        #expect(rows.filter { ProcessScope.all.includes($0, currentUser: "me") }.count == 3)
        #expect(rows.filter { ProcessScope.mine.includes($0, currentUser: "me") }.map(\.pid) == [1])
        #expect(rows.filter { ProcessScope.system.includes($0, currentUser: "me") }.map(\.pid) == [2, 3])
    }

    @Test func portsMergeIPv4AndIPv6() {
        let ports = [
            ListeningPort(address: "127.0.0.1", port: 8787, pid: 10, processName: "python3.1"),
            ListeningPort(address: "::1", port: 8787, pid: 10, processName: "python3.1"),
            ListeningPort(address: "*", port: 5432, pid: 20, processName: "com.docker.bac"),
            ListeningPort(address: "::1", port: 5432, pid: 20, processName: "com.docker.bac"),
            ListeningPort(address: "192.168.1.5", port: 11434, pid: 30, processName: "ollama"),
        ]
        let merged = ServicePort.merge(ports, names: [10: "python3.13"])
        #expect(merged.map(\.port) == [5432, 8787, 11434])
        #expect(merged.map(\.reachability) == ["All interfaces", "This Mac only", "192.168.1.5"])
        #expect(merged.filter { !$0.isLoopbackOnly }.count == 2)
        // The process list's full name wins over netstat's truncated one.
        #expect(merged[1].processName == "python3.13")
        #expect(merged[0].runtime == .docker)
    }

    @Test func yoursNeedsAKnownOwner() {
        let port = ServicePort.merge([ListeningPort(address: "*", port: 3000, pid: 42, processName: "node")])[0]
        #expect(port.isOwned(by: "me", users: [42: "me"]))
        #expect(!port.isOwned(by: "me", users: [42: "root"]))
        #expect(!port.isOwned(by: "me", users: [:]))
    }

    @Test func runtimeTilesCountProcessesAndPorts() {
        let processes = [
            ProcessRow(pid: 1, name: "node", cpuPercent: 1, memoryBytes: 100, isPrivileged: false),
            ProcessRow(pid: 2, name: "node", cpuPercent: 2, memoryBytes: 200, isPrivileged: false),
            ProcessRow(pid: 3, name: "python3.13", cpuPercent: 5, memoryBytes: 50, isPrivileged: false),
            ProcessRow(pid: 4, name: "Finder", cpuPercent: 9, memoryBytes: 900, isPrivileged: false),
        ]
        let ports = ServicePort.merge([
            ListeningPort(address: "*", port: 3000, pid: 1, processName: "node"),
            ListeningPort(address: "::1", port: 3000, pid: 1, processName: "node"),
        ])
        let tiles = RuntimeSummary.build(processes: processes, ports: ports)
        #expect(tiles.map(\.runtime) == [.python, .node])
        #expect(tiles[1].detail == "2 processes · 1 listening")
        #expect(tiles[1].memoryBytes == 300)
        #expect(tiles[0].detail == "1 process · 0 listening")
        // Before the first port read, no listening count is claimed.
        #expect(RuntimeSummary.build(processes: processes, ports: nil)[1].detail == "2 processes")
    }

    @Test func developerSearchMatchesPortsAndContainers() {
        let port = ServicePort.merge([ListeningPort(address: "*", port: 5432, pid: 7, processName: "postgres")])[0]
        #expect(DeveloperSearch.matches(port, "543"))
        #expect(DeveloperSearch.matches(port, "PostgreSQL"))
        #expect(!DeveloperSearch.matches(port, "redis"))
        let container = DockerContainer(id: "a", name: "db", image: "postgres:16-alpine", state: "running", status: "Up")
        #expect(DeveloperSearch.matches(container, "alpine"))
        #expect(!DeveloperSearch.matches(container, "node"))
    }
}
