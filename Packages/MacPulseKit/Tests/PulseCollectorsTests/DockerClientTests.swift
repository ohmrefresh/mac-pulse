import Foundation
import Testing
@testable import PulseCollectors

@Suite struct DockerClientTests {
    @Test func bodyOnlyFor200() {
        let ok = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[1]".utf8)
        #expect(DockerClient.body(of: ok) == Data("[1]".utf8))
        #expect(DockerClient.body(of: Data("HTTP/1.0 404 Not Found\r\n\r\n{}".utf8)) == nil)
        #expect(DockerClient.body(of: Data("garbage".utf8)) == nil)
    }

    @Test func socketPathPrefersDockerHost() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let custom = dir.appending(path: "custom.sock").path
        FileManager.default.createFile(atPath: custom, contents: nil)
        #expect(DockerClient.socketPath(environment: ["DOCKER_HOST": "unix://\(custom)"], home: "/nonexistent") == custom)
        #expect(DockerClient.socketPath(environment: ["DOCKER_HOST": "tcp://1.2.3.4:2375"], home: dir.path)
                == (FileManager.default.fileExists(atPath: "/var/run/docker.sock") ? "/var/run/docker.sock" : nil))
    }

    @Test func cpuFromConsecutiveOneShotSamples() throws {
        func stats(_ total: UInt64, _ system: UInt64) throws -> DockerClient.Stats {
            try JSONDecoder().decode(DockerClient.Stats.self, from: Data("""
            {"cpu_stats":{"cpu_usage":{"total_usage":\(total)},"system_cpu_usage":\(system),"online_cpus":8},
             "memory_stats":{"usage":1000,"limit":8000,"stats":{"inactive_file":200}}}
            """.utf8))
        }
        let c = DockerContainer(id: "a", name: "web", image: "nginx", state: "running", status: "Up")
        var tracker = DockerStatsTracker()
        let first = tracker.apply(try stats(1_000, 100_000), to: c)
        #expect(first.cpuPercent == nil)                    // no baseline yet
        #expect(first.memoryBytes == 800 && first.memoryLimitBytes == 8000)
        // 500 of 10 000 system ticks across 8 CPUs = 40% of one core.
        #expect(tracker.apply(try stats(1_500, 110_000), to: c).cpuPercent == 40)
    }
}

/// Needs a running Docker: `PULSE_DOCKER=1 swift test --filter LiveDockerTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSE_DOCKER"] != nil))
struct LiveDockerTests {
    @Test func listsAndSamplesContainers() throws {
        let socket = try #require(DockerClient.socketPath())
        let list = try #require(DockerClient.containers(socket: socket))
        var tracker = DockerStatsTracker()
        _ = tracker.annotate(list, socket: socket)
        Thread.sleep(forTimeInterval: 1)
        let annotated = tracker.annotate(list, socket: socket)
        for c in annotated where c.isRunning {
            print("DOCKER \(c.name) cpu=\(c.cpuPercent.map { String(format: "%.1f", $0) } ?? "-") mem=\(c.memoryBytes ?? 0)")
            #expect(c.cpuPercent != nil && c.memoryBytes != nil)
        }
        print("DOCKER total \(list.count), running \(list.filter(\.isRunning).count)")
    }
}
