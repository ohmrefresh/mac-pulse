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

    public var average: Double? {
        storage.isEmpty ? nil : storage.reduce(0, +) / Double(storage.count)
    }
}
