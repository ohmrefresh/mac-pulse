import Foundation

/// Summary of a probe series where NaN is a timeout (the `latencyHistory` convention).
public struct LatencyStats: Sendable, Equatable {
    /// Latest round trip; nil when the latest probe timed out or there are none.
    public var current: Double?
    public var median: Double?
    /// Nearest rank: the value at ceil(0.95 × n) of the successful probes in ascending order.
    public var p95: Double?
    public var max: Double?
    /// Mean absolute difference between consecutive successful probes; a timeout breaks the pair.
    /// Nil when no two consecutive probes both succeeded.
    public var jitter: Double?
    public var timeouts: Int
    public var probes: Int
    /// Nil when there are no probes.
    public var lossPercent: Double?

    public init(_ values: [Double]) {
        probes = values.count
        timeouts = values.count { $0.isNaN }
        current = values.last.flatMap { $0.isNaN ? nil : $0 }
        lossPercent = probes == 0 ? nil : Double(timeouts) / Double(probes) * 100

        let sorted = values.filter { !$0.isNaN }.sorted()
        let n = sorted.count
        median = n == 0 ? nil : n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        p95 = n == 0 ? nil : sorted[Int((0.95 * Double(n)).rounded(.up)) - 1]
        max = sorted.last

        let steps = zip(values, values.dropFirst()).compactMap { a, b in a.isNaN || b.isNaN ? nil : abs(b - a) }
        jitter = steps.isEmpty ? nil : steps.reduce(0, +) / Double(steps.count)
    }
}

public enum Transferred {
    /// Bytes moved over the newest `window` seconds of a rate series sampled every `interval` seconds.
    /// NaN samples (gaps) count as nothing.
    public static func bytes(rates: [Double], interval: TimeInterval, window: TimeInterval = 300) -> Double {
        guard interval > 0 else { return 0 }
        return rates.suffix(Int(window / interval)).filter { !$0.isNaN }.reduce(0, +) * interval
    }
}

public enum Peak {
    /// Largest finite sample and its index; the latest one on a tie.
    public static func of(_ values: [Double]) -> (value: Double, index: Int)? {
        var best: (value: Double, index: Int)?
        for (index, value) in values.enumerated() where value.isFinite && value >= (best?.value ?? -.infinity) {
            best = (value, index)
        }
        return best
    }
}
