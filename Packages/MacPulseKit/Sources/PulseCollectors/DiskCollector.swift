import Foundation

public struct DiskReading: Sendable, Equatable {
    public var volumeName: String?
    public var totalBytes: Int64
    /// Space available for important use (includes purgeable), matching Finder / System Settings.
    public var availableBytes: Int64

    public init(volumeName: String?, totalBytes: Int64, availableBytes: Int64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }
}

public struct DiskCollector: Sendable {
    public var volume: URL

    public init(volume: URL = URL(fileURLWithPath: "/")) {
        self.volume = volume
    }

    public func sample() -> DiskReading? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskReading(volumeName: values.volumeName, totalBytes: Int64(total), availableBytes: available)
    }
}
