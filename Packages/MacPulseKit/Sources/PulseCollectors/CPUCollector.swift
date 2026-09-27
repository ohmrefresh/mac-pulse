import Darwin

/// Cumulative per-core tick counters as reported by the kernel.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// (busy, total) ticks elapsed since `earlier`. Kernel counters are 32-bit and wrap,
    /// so each field is differenced in 32-bit wrapping arithmetic before widening.
    func elapsed(since earlier: CPUTicks) -> (busy: UInt64, total: UInt64) {
        let busy = UInt64(user &- earlier.user) + UInt64(system &- earlier.system) + UInt64(nice &- earlier.nice)
        return (busy, busy + UInt64(idle &- earlier.idle))
    }
}

public struct CPUReading: Sendable, Equatable {
    /// 0...100, averaged over all cores.
    public var totalPercent: Double
    /// 0...100 per core, in kernel order.
    public var perCorePercent: [Double]

    public init(totalPercent: Double, perCorePercent: [Double]) {
        self.totalPercent = totalPercent
        self.perCorePercent = perCorePercent
    }
}

public enum CPUUsage {
    /// Usage between two cumulative snapshots. Returns nil if core counts differ.
    public static func reading(from previous: [CPUTicks], to current: [CPUTicks]) -> CPUReading? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var busySum: UInt64 = 0
        var totalSum: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        for (old, new) in zip(previous, current) {
            let (busy, total) = new.elapsed(since: old)
            busySum += busy
            totalSum += total
            perCore.append(total == 0 ? 0 : Double(busy) / Double(total) * 100)
        }
        let totalPercent = totalSum == 0 ? 0 : Double(busySum) / Double(totalSum) * 100
        return CPUReading(totalPercent: totalPercent, perCorePercent: perCore)
    }
}

/// Delta-based CPU collector. The first `sample()` only primes the baseline and returns nil.
public struct CPUCollector: Sendable {
    private var previous: [CPUTicks]?

    public init() {}

    public mutating func sample() -> CPUReading? {
        guard let current = Self.readTicks() else { return nil }
        defer { previous = current }
        guard let previous else { return nil }
        return CPUUsage.reading(from: previous, to: current)
    }

    public static func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CPUTicks(
                user: tick(CPU_STATE_USER),
                system: tick(CPU_STATE_SYSTEM),
                idle: tick(CPU_STATE_IDLE),
                nice: tick(CPU_STATE_NICE)
            )
        }
    }

    public static func processorName() -> String? {
        Sysctl.string("machdep.cpu.brand_string")
    }
}
