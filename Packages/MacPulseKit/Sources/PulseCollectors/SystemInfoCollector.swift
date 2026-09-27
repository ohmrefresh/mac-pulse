import Darwin
import Foundation

/// One core cluster, named by the kernel itself. The names are not fixed: an M5 Pro reports
/// "Super" and "Performance", earlier Apple Silicon reports "Performance" and "Efficiency" —
/// so the name is read, never assumed from the perflevel index.
public struct CPUCluster: Sendable, Equatable, Identifiable {
    public var name: String
    public var logicalCount: Int
    public var id: String { name }

    public init(name: String, logicalCount: Int) {
        self.name = name
        self.logicalCount = logicalCount
    }
}

/// CPU topology: fixed for the life of the process, so it is read once.
public struct CPUTopology: Sendable, Equatable {
    public var logicalCount: Int?
    public var physicalCount: Int?
    /// Fastest first. Empty on Intel, which has a single kind of core and no perflevels.
    public var clusters: [CPUCluster]
    /// Intel only: Apple Silicon publishes no frequency through sysctl (see `IOReportClient`).
    public var maxFrequencyHz: Double?

    public init(logicalCount: Int? = nil, physicalCount: Int? = nil, clusters: [CPUCluster] = [],
                maxFrequencyHz: Double? = nil) {
        self.logicalCount = logicalCount
        self.physicalCount = physicalCount
        self.clusters = clusters
        self.maxFrequencyHz = maxFrequencyHz
    }
}

/// The kernel's run-queue averages over 1, 5 and 15 minutes — a count of runnable threads,
/// not a percentage, so it is not capped at 100.
public struct LoadAverage: Sendable, Equatable {
    public var oneMinute: Double
    public var fiveMinutes: Double
    public var fifteenMinutes: Double

    public init(oneMinute: Double, fiveMinutes: Double, fifteenMinutes: Double) {
        self.oneMinute = oneMinute
        self.fiveMinutes = fiveMinutes
        self.fifteenMinutes = fifteenMinutes
    }

    /// `getloadavg(3)` fills three slots; anything short, negative or non-finite means the read failed.
    public init?(raw: [Double]) {
        guard raw.count >= 3, raw.prefix(3).allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        self.init(oneMinute: raw[0], fiveMinutes: raw[1], fifteenMinutes: raw[2])
    }
}

/// Machine facts from public sysctls: core layout, load average and boot time.
public enum SystemInfoCollector {
    public static func topology() -> CPUTopology {
        CPUTopology(
            logicalCount: int32("hw.logicalcpu"),
            physicalCount: int32("hw.physicalcpu"),
            clusters: clusters(),
            maxFrequencyHz: (Sysctl.value("hw.cpufrequency_max") as Int64?).map(Double.init)
        )
    }

    /// perflevel0 is the fastest cluster. Absent on Intel, which reports no perflevels.
    static func clusters() -> [CPUCluster] {
        guard let levels = int32("hw.nperflevels"), levels > 0 else { return [] }
        return (0..<levels).compactMap { level in
            guard let count = int32("hw.perflevel\(level).logicalcpu"),
                  let name = Sysctl.string("hw.perflevel\(level).name") else { return nil }
            return CPUCluster(name: name, logicalCount: count)
        }
    }

    public static func loadAverage() -> LoadAverage? {
        var raw = [Double](repeating: 0, count: 3)
        guard getloadavg(&raw, 3) == 3 else { return nil }
        return LoadAverage(raw: raw)
    }

    public static func bootTime() -> Date? {
        var tv = timeval()
        guard Sysctl.raw("kern.boottime", into: &tv), tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    private static func int32(_ name: String) -> Int? {
        (Sysctl.value(name) as Int32?).map(Int.init)
    }
}
