import Darwin
import Foundation

public struct ProcessRow: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Activity Monitor convention: percent of one core, so it can exceed 100 on multi-core Macs.
    public var cpuPercent: Double
    /// Physical footprint for directly readable processes; resident size for privileged ones (from `ps`).
    public var memoryBytes: UInt64
    /// Owned by root or another system account; refreshed only on the slower `ps` cadence.
    public var isPrivileged: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64, isPrivileged: Bool) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.isPrivileged = isPrivileged
    }
}

/// Turns cumulative per-process CPU time into a percentage between consecutive observations.
/// `identity` distinguishes a reused PID from the process that previously held it.
struct CPUTimeTracker<Identity: Hashable & Sendable>: Sendable {
    private var previous: [Int32: (identity: Identity, cpuNanos: UInt64, at: TimeInterval)] = [:]

    /// Nil on first observation of a process (no baseline yet).
    mutating func percent(pid: Int32, identity: Identity, cpuNanos: UInt64, at now: TimeInterval) -> Double? {
        defer { previous[pid] = (identity, cpuNanos, now) }
        guard let last = previous[pid], last.identity == identity,
              now > last.at, cpuNanos >= last.cpuNanos else { return nil }
        return Double(cpuNanos - last.cpuNanos) / ((now - last.at) * 1e9) * 100
    }

    mutating func forgetAll(except pids: Set<Int32>) {
        previous = previous.filter { pids.contains($0.key) }
    }
}

public struct ProcessCollector: Sendable {
    private var directTracker = CPUTimeTracker<UInt64>()
    private var privilegedTracker = CPUTimeTracker<String>()
    private var names: [Int32: (startTime: UInt64, name: String)] = [:]
    private var privilegedRows: [Int32: ProcessRow] = [:]

    public init() {}

    /// - Parameter refreshPrivileged: run `/bin/ps` to refresh processes this app cannot read directly.
    ///   Between refreshes the last privileged values are reused.
    public mutating func sample(refreshPrivileged: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [ProcessRow] {
        let pids = Self.allPIDs()
        var rows: [ProcessRow] = []
        rows.reserveCapacity(pids.count)
        var readable = Set<Int32>()

        for pid in pids {
            guard let usage = Self.rusage(pid) else { continue }
            readable.insert(pid)
            let name = cachedName(pid: pid, startTime: usage.startTime)
            let percent = directTracker.percent(pid: pid, identity: usage.startTime, cpuNanos: usage.cpuNanos, at: now) ?? 0
            rows.append(ProcessRow(pid: pid, name: name, cpuPercent: percent, memoryBytes: usage.footprint, isPrivileged: false))
        }
        directTracker.forgetAll(except: readable)
        names = names.filter { readable.contains($0.key) }

        let unreadable = pids.filter { !readable.contains($0) }
        if refreshPrivileged, !unreadable.isEmpty, let output = Self.runPS(pids: unreadable) {
            var fresh: [Int32: ProcessRow] = [:]
            for entry in PSParser.parse(output) where !readable.contains(entry.pid) {
                let percent = privilegedTracker.percent(pid: entry.pid, identity: entry.name, cpuNanos: entry.cpuNanos, at: now) ?? 0
                fresh[entry.pid] = ProcessRow(pid: entry.pid, name: entry.name, cpuPercent: percent,
                                              memoryBytes: entry.residentBytes, isPrivileged: true)
            }
            privilegedTracker.forgetAll(except: Set(fresh.keys))
            privilegedRows = fresh
        }
        let alive = Set(pids)
        rows.append(contentsOf: privilegedRows.values.filter { alive.contains($0.pid) && !readable.contains($0.pid) })
        return rows
    }

    private mutating func cachedName(pid: Int32, startTime: UInt64) -> String {
        if let cached = names[pid], cached.startTime == startTime { return cached.name }
        let name = Self.name(of: pid)
        names[pid] = (startTime, name)
        return name
    }

    // MARK: - System calls

    static func allPIDs() -> [Int32] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        return pids.prefix(max(count, 0)).filter { $0 > 0 }
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    static func rusage(_ pid: Int32) -> (cpuNanos: UInt64, footprint: UInt64, startTime: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // ri_*_time is in mach absolute time units (not ns) on Apple Silicon.
        let ticks = info.ri_user_time &+ info.ri_system_time
        let nanos = ticks.multipliedFullWidth(by: timebase.numer)
        let cpuNanos = timebase.denom.dividingFullWidth(nanos).quotient
        return (cpuNanos, info.ri_phys_footprint, info.ri_proc_start_abstime)
    }

    static func name(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return (path as NSString).lastPathComponent
        }
        return "pid \(pid)"
    }

    /// `/bin/ps` is setuid root, so it can read processes this unprivileged app cannot.
    /// Only the given PIDs are queried; `-c` prints executable names instead of full paths.
    static func runPS(pids: [Int32]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-c", "-o", "pid=,time=,rss=,comm=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain before waiting: output can exceed the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

struct PSEntry: Equatable {
    var pid: Int32
    var cpuNanos: UInt64
    var residentBytes: UInt64
    var name: String
}

enum PSParser {
    /// Parses `ps -o pid=,time=,rss=,comm=` output. `comm` is last because it may contain spaces.
    static func parse(_ output: String) -> [PSEntry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let cpu = cpuNanos(fields[1]),
                  let rssKB = UInt64(fields[2]) else { return nil }
            let command = fields[3].trimmingCharacters(in: .whitespaces)
            let name = (command as NSString).lastPathComponent
            return PSEntry(pid: pid, cpuNanos: cpu, residentBytes: rssKB * 1024, name: name.isEmpty ? command : name)
        }
    }

    /// Accepts `[dd-][hh:]mm:ss[.cc]`.
    static func cpuNanos<S: StringProtocol>(_ text: S) -> UInt64? {
        var rest = Substring(text)
        var days: Double = 0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var clock: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            clock = clock * 60 + value
        }
        return UInt64(((days * 86_400 + clock) * 1e9).rounded())
    }
}
