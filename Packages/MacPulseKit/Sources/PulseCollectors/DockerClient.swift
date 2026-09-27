import Darwin
import Foundation

public struct DockerContainer: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    /// "running", "exited", "paused", …
    public var state: String
    /// Human status from Docker, e.g. "Up 3 hours".
    public var status: String
    /// Percent of one core; nil until two stats samples exist or when not running.
    public var cpuPercent: Double?
    /// Usage minus reclaimable page cache, as `docker stats` reports.
    public var memoryBytes: UInt64?
    public var memoryLimitBytes: UInt64?

    public var isRunning: Bool { state == "running" }

    public init(id: String, name: String, image: String, state: String, status: String,
                cpuPercent: Double? = nil, memoryBytes: UInt64? = nil, memoryLimitBytes: UInt64? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
    }
}

/// Docker Engine API over its Unix socket (Docker Desktop, OrbStack, Colima, …).
public enum DockerClient {
    /// First existing socket: $DOCKER_HOST (unix://), then the common per-product locations.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String? {
        var candidates: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") { candidates.append(String(host.dropFirst(7))) }
        candidates += ["\(home)/.docker/run/docker.sock", "/var/run/docker.sock",
                       "\(home)/.orbstack/run/docker.sock", "\(home)/.colima/default/docker.sock"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    struct Summary: Decodable {
        let Id: String
        let Names: [String]
        let Image: String
        let State: String
        let Status: String
    }

    struct Stats: Decodable {
        struct CPU: Decodable {
            struct Usage: Decodable { let total_usage: UInt64 }
            let cpu_usage: Usage
            let system_cpu_usage: UInt64?
            let online_cpus: Int?
        }
        struct Memory: Decodable {
            let usage: UInt64?
            let limit: UInt64?
            let stats: [String: UInt64]?
        }
        let cpu_stats: CPU
        let memory_stats: Memory
    }

    /// Nil when Docker is not reachable (not installed, not running).
    public static func containers(socket: String) -> [DockerContainer]? {
        guard let body = get("/containers/json?all=true", socket: socket),
              let list = try? JSONDecoder().decode([Summary].self, from: body) else { return nil }
        return list.map {
            DockerContainer(id: $0.Id, name: $0.Names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String($0.Id.prefix(12)),
                            image: $0.Image, state: $0.State, status: $0.Status)
        }
    }

    static func stats(id: String, socket: String) -> Stats? {
        guard let body = get("/containers/\(id)/stats?stream=false&one-shot=true", socket: socket) else { return nil }
        return try? JSONDecoder().decode(Stats.self, from: body)
    }

    /// Minimal HTTP/1.0 GET: the daemon closes the connection after one un-chunked response.
    static func get(_ path: String, socket socketPath: String, timeout: TimeInterval = 3) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }

        let request = Array("GET \(path) HTTP/1.0\r\nHost: docker\r\n\r\n".utf8)
        guard request.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == request.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { response.append(contentsOf: buffer[..<n]) } else { break }
            if response.count > 8 << 20 { return nil }     // refuse absurd responses
        }
        return body(of: response)
    }

    /// Body of a 200 response; nil for other statuses or malformed data.
    static func body(of response: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator),
              let statusLine = String(data: response[..<range.lowerBound], encoding: .utf8)?.split(separator: "\r\n").first,
              statusLine.split(separator: " ").dropFirst().first == "200" else { return nil }
        return response[range.upperBound...]
    }
}

/// Keeps the previous CPU counters per container so `one-shot` stats (no precpu) still give a rate.
public struct DockerStatsTracker: Sendable {
    private var previous: [String: (container: UInt64, system: UInt64)] = [:]

    public init() {}

    /// Fills cpu/memory for running containers. Stats calls take ~10 ms each.
    public mutating func annotate(_ containers: [DockerContainer], socket: String) -> [DockerContainer] {
        var seen = Set<String>()
        let result = containers.map { container -> DockerContainer in
            guard container.isRunning, let stats = DockerClient.stats(id: container.id, socket: socket) else { return container }
            seen.insert(container.id)
            return apply(stats, to: container)
        }
        previous = previous.filter { seen.contains($0.key) }
        return result
    }

    mutating func apply(_ stats: DockerClient.Stats, to container: DockerContainer) -> DockerContainer {
        var c = container
        let total = stats.cpu_stats.cpu_usage.total_usage
        if let system = stats.cpu_stats.system_cpu_usage {
            if let last = previous[c.id], system > last.system, total >= last.container {
                let cpus = Double(stats.cpu_stats.online_cpus ?? 1)
                c.cpuPercent = Double(total - last.container) / Double(system - last.system) * cpus * 100
            }
            previous[c.id] = (total, system)
        }
        if let usage = stats.memory_stats.usage {
            let cache = stats.memory_stats.stats?["inactive_file"] ?? stats.memory_stats.stats?["total_inactive_file"] ?? 0
            c.memoryBytes = usage > cache ? usage - cache : usage
        }
        c.memoryLimitBytes = stats.memory_stats.limit
        return c
    }
}
