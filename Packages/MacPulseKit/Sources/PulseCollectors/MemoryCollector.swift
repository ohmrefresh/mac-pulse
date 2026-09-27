import Darwin
import Foundation
import PulseCore

public struct MemoryReading: Sendable, Equatable {
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    /// Activity Monitor's "Cached Files": file-backed and purgeable pages. Not part of Memory Used —
    /// the system reclaims them on demand.
    public var cachedFilesBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: MemoryPressure?

    public init(totalBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                cachedFilesBytes: UInt64 = 0, swapUsedBytes: UInt64, pressure: MemoryPressure?) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }

    /// Same definition as Activity Monitor's "Memory Used".
    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    public var usedPercent: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
    }

    /// Whatever installed RAM is left once Used and Cached Files are accounted for, so that
    /// used + cached + free is exactly the installed total (what the memory ring draws).
    public var freeBytes: UInt64 {
        let accounted = usedBytes + cachedFilesBytes
        return totalBytes > accounted ? totalBytes - accounted : 0
    }
}

public struct MemoryCollector: Sendable {
    public init() {}

    public func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return Self.reading(
            pages: PageCounts(internalPages: UInt64(stats.internal_page_count),
                              purgeable: UInt64(stats.purgeable_count),
                              wired: UInt64(stats.wire_count),
                              compressor: UInt64(stats.compressor_page_count),
                              external: UInt64(stats.external_page_count)),
            pageSize: UInt64(pageSize),
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: Self.swapUsedBytes() ?? 0,
            pressure: Self.pressure()
        )
    }

    /// The page counts the reading is derived from, so the arithmetic is testable without a live kernel.
    public struct PageCounts: Sendable, Equatable {
        public var internalPages: UInt64
        public var purgeable: UInt64
        public var wired: UInt64
        public var compressor: UInt64
        public var external: UInt64

        public init(internalPages: UInt64, purgeable: UInt64, wired: UInt64, compressor: UInt64, external: UInt64) {
            self.internalPages = internalPages
            self.purgeable = purgeable
            self.wired = wired
            self.compressor = compressor
            self.external = external
        }
    }

    /// Activity Monitor's split: App = internal − purgeable, Cached Files = external + purgeable.
    public static func reading(pages: PageCounts, pageSize: UInt64, totalBytes: UInt64,
                               swapUsedBytes: UInt64, pressure: MemoryPressure?) -> MemoryReading {
        MemoryReading(
            totalBytes: totalBytes,
            appBytes: (pages.internalPages > pages.purgeable ? pages.internalPages - pages.purgeable : 0) * pageSize,
            wiredBytes: pages.wired * pageSize,
            compressedBytes: pages.compressor * pageSize,
            cachedFilesBytes: (pages.external + pages.purgeable) * pageSize,
            swapUsedBytes: swapUsedBytes,
            pressure: pressure
        )
    }

    static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    static func pressure() -> MemoryPressure? {
        guard let level: Int32 = Sysctl.value("kern.memorystatus_vm_pressure_level") else { return nil }
        return pressure(kernelLevel: level)
    }

    /// Kernel levels: 1 normal, 2 warning, 4 critical.
    static func pressure(kernelLevel: Int32) -> MemoryPressure? {
        switch kernelLevel {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }
}
