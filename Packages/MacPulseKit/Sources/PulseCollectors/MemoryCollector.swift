import Darwin
import Foundation
import PulseCore

public struct MemoryReading: Sendable, Equatable {
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: MemoryPressure?

    public init(totalBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                swapUsedBytes: UInt64, pressure: MemoryPressure?) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }

    /// Same definition as Activity Monitor's "Memory Used".
    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    public var usedPercent: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
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
        let page = UInt64(pageSize)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemoryReading(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            appBytes: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            swapUsedBytes: Self.swapUsedBytes() ?? 0,
            pressure: Self.pressure()
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
