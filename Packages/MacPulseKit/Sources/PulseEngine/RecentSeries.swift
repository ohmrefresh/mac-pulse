import Foundation

/// Fixed-capacity in-memory series for sparklines and short averages. Persistent history is PulseStore's job.
public struct RecentSeries: Sendable, Equatable {
    public let capacity: Int
    private var storage: [Double] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public mutating func append(_ value: Double) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    public var values: [Double] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }

    /// Most recent `count` values, oldest first.
    public func suffix(_ count: Int) -> [Double] {
        Array(values.suffix(count))
    }

    public var count: Int { storage.count }

    public var average: Double? {
        storage.isEmpty ? nil : storage.reduce(0, +) / Double(storage.count)
    }

    /// Mean of the newest `seconds` of wall time, given how far apart samples are. NaN gaps are skipped.
    public func average(lastSeconds seconds: TimeInterval, interval: TimeInterval) -> Double? {
        guard interval > 0 else { return nil }
        let recent = suffix(max(1, Int((seconds / interval).rounded()))).filter { !$0.isNaN }
        return recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
    }

    /// Latest value minus its recent average — the cards' \"vs 5m avg\" delta. Nil until the series
    /// spans `minimumSpan` of wall time, so a freshly launched app shows no arrow rather than a wrong one.
    public func trend(lastSeconds seconds: TimeInterval = 300, interval: TimeInterval,
                      minimumSpan: TimeInterval = 150) -> Double? {
        guard interval > 0, Double(count) * interval >= minimumSpan,
              let last = values.last, !last.isNaN,
              let mean = average(lastSeconds: seconds, interval: interval) else { return nil }
        return last - mean
    }
}

/// Capped series of timestamped values, for readings on an irregular cadence (sensors: 5–60 s)
/// where "change over the last N minutes" must use wall time, not sample count.
public struct TimedSeries: Sendable, Equatable {
    public let capacity: Int
    public private(set) var samples: [(time: Date, value: Double)] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func append(_ value: Double, at time: Date) {
        samples.append((time, value))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Oldest first.
    public var values: [Double] { samples.map(\.value) }

    /// Latest value minus the newest value at least `interval` older; nil until the series spans `interval`.
    public func change(over interval: TimeInterval) -> Double? {
        guard let last = samples.last,
              let base = samples.last(where: { last.time.timeIntervalSince($0.time) >= interval }) else { return nil }
        return last.value - base.value
    }

    /// Latest value minus its average over `interval`, matching `RecentSeries.trend` for series
    /// whose cadence varies (sensors run at 5 s or 60 s depending on what is on screen).
    public func trend(over interval: TimeInterval = 300, minimumSpan: TimeInterval = 150) -> Double? {
        guard let last = samples.last, let first = samples.first,
              last.time.timeIntervalSince(first.time) >= minimumSpan else { return nil }
        let window = samples.filter { last.time.timeIntervalSince($0.time) <= interval }
        guard !window.isEmpty else { return nil }
        return last.value - window.reduce(0) { $0 + $1.value } / Double(window.count)
    }

    public static func == (lhs: TimedSeries, rhs: TimedSeries) -> Bool {
        lhs.capacity == rhs.capacity && lhs.samples.elementsEqual(rhs.samples) { $0.time == $1.time && $0.value == $1.value }
    }
}
