import Foundation

public struct DiskReading: Sendable, Equatable {
    public var volumeName: String?
    public var totalBytes: Int64
    /// Space available for important use (includes purgeable), matching Finder / System Settings.
    /// Other volumes in `sampleVolumes` report fresh statfs free space, which excludes purgeable;
    /// external volumes rarely have any.
    public var availableBytes: Int64
    /// Mount point, e.g. "/" or "/Volumes/Backup".
    public var mountPath: String?
    /// Nil when the volume doesn't say; only the startup disk reports it.
    public var isInternal: Bool?
    public var isRemovable: Bool?

    public init(volumeName: String?, totalBytes: Int64, availableBytes: Int64, mountPath: String? = nil,
                isInternal: Bool? = nil, isRemovable: Bool? = nil) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.mountPath = mountPath
        self.isInternal = isInternal
        self.isRemovable = isRemovable
    }

    public var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }
}

public struct DiskCollector: Sendable {
    public var volume: URL

    public init(volume: URL = URL(fileURLWithPath: "/")) {
        self.volume = volume
    }

    public func sample() -> DiskReading? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsInternalKey, .volumeIsRemovableKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskReading(volumeName: values.volumeName, totalBytes: Int64(total), availableBytes: available,
                           mountPath: volume.path, isInternal: values.volumeIsInternal, isRemovable: values.volumeIsRemovable)
    }

    /// Every mounted local Volume the user sees, `startup` (this tick's `sample()`) first.
    /// The cached mount table only lists and filters them, so network servers are never asked (a
    /// stale one would stall the Sampler). Each local volume then gets a fresh `statfs`, answered
    /// from the filesystem's in-memory counters with no purgeable query.
    public static func sampleVolumes(startup: DiskReading?) -> [DiskReading] {
        volumes(from: mounts(), startup: startup, refresh: freshStatfs)
    }

    /// `refresh` re-reads one listed mount; it runs only for volumes that pass `userVolumes`.
    static func volumes(from mounts: [Mount], startup: DiskReading?,
                        refresh: (Mount) -> Mount?) -> [DiskReading] {
        let byPath = Dictionary(mounts.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return userVolumes(mounts).compactMap { path in
            if path == "/" { return startup }
            guard let listed = byPath[path], let m = refresh(listed), m.blocks > 0 else { return nil }
            return DiskReading(volumeName: URL(fileURLWithPath: path).lastPathComponent,
                               totalBytes: Int64(m.blocks * m.blockSize),
                               availableBytes: Int64(min(m.availableBlocks, m.blocks) * m.blockSize),
                               mountPath: path, isRemovable: m.flags & UInt32(MNT_REMOVABLE) != 0)
        }
    }

    struct Mount: Equatable {
        var path: String
        var flags: UInt32
        var blockSize: UInt64 = 0
        var blocks: UInt64 = 0
        var availableBlocks: UInt64 = 0
    }

    /// Fresh figures for one local mount; nil if it went away.
    static func freshStatfs(_ m: Mount) -> Mount? {
        var entry = Darwin.statfs()
        guard statfs(m.path, &entry) == 0 else { return nil }
        return Mount(path: m.path, flags: entry.f_flags, blockSize: UInt64(entry.f_bsize),
                     blocks: entry.f_blocks, availableBlocks: entry.f_bavail)
    }

    /// The kernel's mount table as cached (`MNT_NOWAIT`): no filesystem, local or remote, is asked,
    /// so its capacity figures may be stale and are not used.
    static func mounts() -> [Mount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = Array(repeating: Darwin.statfs(), count: Int(count))
        let got = buffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
        }
        guard got > 0 else { return [] }
        return buffer.prefix(Int(got)).map { entry in
            var entry = entry
            let path = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Mount(path: path, flags: entry.f_flags, blockSize: UInt64(entry.f_bsize),
                         blocks: entry.f_blocks, availableBlocks: entry.f_bavail)
        }
    }

    /// Keeps local (`MNT_LOCAL`), browsable (no `MNT_DONTBROWSE`) mounts at "/" (first) or under
    /// /Volumes, in mount order. That drops network volumes, /System/Volumes/* (Data mirrors "/";
    /// VM, Preboot, Recovery, Update, xarts are internal), devfs, simulator runtimes and cryptexes.
    static func userVolumes(_ mounts: [Mount]) -> [String] {
        let kept = mounts.filter {
            $0.flags & UInt32(MNT_LOCAL) != 0 && $0.flags & UInt32(MNT_DONTBROWSE) == 0
                && ($0.path == "/" || $0.path.hasPrefix("/Volumes/"))
        }.map(\.path)
        return kept.filter { $0 == "/" } + kept.filter { $0 != "/" }
    }
}
