import Foundation

public struct ListeningPort: Sendable, Equatable, Identifiable {
    /// Local address as netstat prints it: "*", "127.0.0.1", "::1", "192.168.1.5", …
    public var address: String
    public var port: UInt16
    public var pid: Int32
    /// Possibly truncated by netstat; prefer the process list's name for the same PID.
    public var processName: String

    public var id: String { "\(pid)-\(address)-\(port)" }

    /// Reachable only from this Mac.
    public var isLoopbackOnly: Bool { address == "127.0.0.1" || address == "::1" || address.hasPrefix("127.") }

    public init(address: String, port: UInt16, pid: Int32, processName: String) {
        self.address = address
        self.port = port
        self.pid = pid
        self.processName = processName
    }
}

/// TCP listening sockets with their owning process, via unprivileged `netstat -anv`, which unlike
/// `proc_pidfdinfo` also sees other users' processes.
public enum ListeningPortsCollector {
    public static func sample() -> [ListeningPort] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-anv", "-p", "tcp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return NetstatParser.listening(String(decoding: data, as: UTF8.self))
    }
}

enum NetstatParser {
    /// Parses `netstat -anv -p tcp` LISTEN rows. Columns: proto, recv-q, send-q, local, foreign, state,
    /// rxbytes, txbytes, rhiwat, shiwat, then a fixed-width "name:pid" (the name may contain spaces
    /// and is truncated), then flags. Rows are de-duplicated (tcp4 and tcp6 sockets of one listener).
    static func listening(_ output: String) -> [ListeningPort] {
        var seen = Set<String>()
        var result: [ListeningPort] = []
        for line in output.split(separator: "\n") where line.contains(" LISTEN ") {
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<10 {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { break }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            guard fields.count == 10, fields[5] == "LISTEN",
                  let (address, port) = splitAddress(fields[3]),
                  let owner = processField(rest) else { continue }
            let entry = ListeningPort(address: address, port: port, pid: owner.pid, processName: owner.name)
            if seen.insert(entry.id).inserted { result.append(entry) }
        }
        return result.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// "127.0.0.1.8080" → ("127.0.0.1", 8080); "*.5432" → ("*", 5432); "::1.3000" → ("::1", 3000).
    static func splitAddress<S: StringProtocol>(_ text: S) -> (String, UInt16)? {
        guard let dot = text.lastIndex(of: "."), let port = UInt16(text[text.index(after: dot)...]) else { return nil }
        return (String(text[..<dot]), port)
    }

    /// Reads "name with spaces:1234" up to the pid digits.
    static func processField<S: StringProtocol>(_ text: S) -> (name: String, pid: Int32)? {
        let trimmed = text.drop { $0 == " " }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let digits = trimmed[trimmed.index(after: colon)...].prefix { $0.isNumber }
        guard let pid = Int32(digits) else { return nil }
        return (String(trimmed[..<colon]), pid)
    }
}

/// Developer runtimes and services recognised from a process name (Phase 3 "runtime detection").
public enum DevRuntime: String, Sendable, CaseIterable {
    case java = "Java", node = "Node.js", deno = "Deno", bun = "Bun", python = "Python", ruby = "Ruby"
    case go = "Go", dotnet = ".NET", php = "PHP", erlang = "Erlang/Elixir", rust = "Rust"
    case postgres = "PostgreSQL", mysql = "MySQL", redis = "Redis", mongo = "MongoDB", nginx = "nginx"
    case docker = "Docker", kubernetes = "Kubernetes"

    /// Matches on the executable name; nil for everything else.
    public static func detect(processName raw: String) -> DevRuntime? {
        let name = raw.lowercased()
        func starts(_ prefixes: String...) -> Bool { prefixes.contains { name.hasPrefix($0) } }
        if starts("java") { return .java }
        if name == "node" || starts("node ") { return .node }
        if name == "deno" { return .deno }
        if name == "bun" { return .bun }
        if starts("python", "uvicorn", "gunicorn") { return .python }
        if starts("ruby", "puma", "rails") { return .ruby }
        if name == "go" || starts("gopls") { return .go }
        if name == "dotnet" { return .dotnet }
        if starts("php") { return .php }
        if starts("beam.smp", "erl") { return .erlang }
        if name == "cargo" || name == "rustc" || starts("rust-analyzer") { return .rust }
        if starts("postgres", "postmaster") { return .postgres }
        if starts("mysqld", "mariadbd") { return .mysql }
        if starts("redis-server") { return .redis }
        if starts("mongod") { return .mongo }
        if starts("nginx") { return .nginx }
        if starts("com.docker", "docker", "vpnkit", "orbstack", "colima", "limactl") { return .docker }
        if starts("kubectl", "kind", "minikube", "k3s", "kubelet") { return .kubernetes }
        return nil
    }
}
