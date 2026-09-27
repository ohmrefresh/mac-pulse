import Darwin
import Foundation
import IOKit

/// CPU frequency and GPU power, read through private interfaces (ADR 0003).
/// Every field is optional: a value this Mac does not report stays nil and its row is hidden.
public struct FrequencyReading: Sendable, Equatable {
    /// Residency-weighted average over the fastest CPU cluster while it was running, in hertz.
    public var cpuCurrentHz: Double?
    /// Top DVFS state of that cluster.
    public var cpuMaxHz: Double?
    public var gpuPowerWatts: Double?

    public init(cpuCurrentHz: Double? = nil, cpuMaxHz: Double? = nil, gpuPowerWatts: Double? = nil) {
        self.cpuCurrentHz = cpuCurrentHz
        self.cpuMaxHz = cpuMaxHz
        self.gpuPowerWatts = gpuPowerWatts
    }

    public var isEmpty: Bool { cpuCurrentHz == nil && cpuMaxHz == nil && gpuPowerWatts == nil }
}

/// Pure arithmetic behind the reading, kept out of the IOReport plumbing so it can be tested.
public enum FrequencyMath {
    /// A DVFS table is pairs of (frequency, voltage) little-endian UInt32. Zero entries are padding.
    public static func states(from data: Data) -> [Double] {
        guard data.count >= 8 else { return [] }
        return stride(from: 0, to: data.count - 7, by: 8).compactMap { offset in
            let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return raw == 0 ? nil : Double(raw)
        }
    }

    /// Tables are in hertz on some chips and kilohertz on others. Scale to hertz by magnitude:
    /// no Mac runs below 100 MHz or above 100 GHz, so the right factor is unambiguous.
    public static func normalizeToHertz(_ values: [Double]) -> [Double] {
        guard let peak = values.max(), peak > 0 else { return [] }
        let factor: Double
        switch peak {
        case 1e8...1e11: factor = 1            // already hertz
        case 1e5...1e8: factor = 1_000         // kilohertz
        case 100...1e5: factor = 1_000_000     // megahertz
        default: return []                     // not a frequency table we understand
        }
        return values.map { $0 * factor }
    }

    /// A real DVFS ladder climbs from a low state to a high one and stays inside the range any
    /// Apple CPU or GPU can clock at. Tables that fail either test are some other kind of data.
    public static func isFrequencyLadder(_ states: [Double]) -> Bool {
        guard states.count > 1, let low = states.first, let high = states.last else { return false }
        guard states == states.sorted(), low < high else { return false }
        return low >= 1e8 && high <= 7e9
    }

    /// Average frequency over the states that actually ran. Residencies are ticks per state,
    /// aligned with `frequencies`; idle and off states are excluded by the caller.
    public static func weightedFrequency(residencies: [Double], frequencies: [Double]) -> Double? {
        let pairs = zip(residencies, frequencies).filter { $0.0 > 0 }
        let ticks = pairs.reduce(0) { $0 + $1.0 }
        guard ticks > 0 else { return nil }     // the cluster was idle for the whole interval
        return pairs.reduce(0) { $0 + $1.0 * $1.1 } / ticks
    }

    /// Energy Model reports energy since the previous sample, but not in one fixed unit: on this
    /// hardware CPU Energy arrives in mJ and GPU Energy in nJ, so the channel's own unit label
    /// decides the scale. An unrecognised label yields nil rather than a number off by 10^6.
    public static func watts(energy: Double, unit: String, seconds: Double) -> Double? {
        guard seconds > 0, energy >= 0 else { return nil }
        let joules: Double
        switch unit.trimmingCharacters(in: .whitespaces).lowercased() {
        case "nj": joules = energy * 1e-9
        case "uj", "\u{00b5}j": joules = energy * 1e-6
        case "mj": joules = energy * 1e-3
        case "j": joules = energy
        default: return nil
        }
        return joules / seconds
    }
}

/// Minimal read-only IOReport client. Subscribes to CPU complex performance states and the
/// Energy Model, and turns two samples into a frequency and a power figure.
///
/// IOReport is private and undocumented: it is loaded by `dlopen`, every lookup is optional, and
/// any failure yields nil rather than a crash or a wrong number (the ADR 0002 rule). Nothing
/// outside the Performance page depends on it.
public final class IOReportClient: @unchecked Sendable {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias SimpleValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createSamplesDelta: CreateSamplesDelta
    private let channelGroup: ChannelString
    private let channelSubgroup: ChannelString
    private let channelName: ChannelString
    private let channelUnit: ChannelString
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency
    private let simpleValue: SimpleValue

    private let subscription: UnsafeMutableRawPointer
    private let channels: CFMutableDictionary
    /// DVFS tables from the power manager, in hertz, longest first.
    private let dvfsTables: [[Double]]

    private let lock = NSLock()
    private var previous: CFDictionary?
    private var previousTime: TimeInterval?

    public init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let copyChannels: CopyChannels = symbol("IOReportCopyChannelsInGroup"),
              let mergeChannels: MergeChannels = symbol("IOReportMergeChannels"),
              let createSubscription: CreateSubscription = symbol("IOReportCreateSubscription"),
              let createSamples: CreateSamples = symbol("IOReportCreateSamples"),
              let createSamplesDelta: CreateSamplesDelta = symbol("IOReportCreateSamplesDelta"),
              let channelGroup: ChannelString = symbol("IOReportChannelGetGroup"),
              let channelSubgroup: ChannelString = symbol("IOReportChannelGetSubGroup"),
              let channelName: ChannelString = symbol("IOReportChannelGetChannelName"),
              let channelUnit: ChannelString = symbol("IOReportChannelGetUnitLabel"),
              let stateCount: StateCount = symbol("IOReportStateGetCount"),
              let stateName: StateName = symbol("IOReportStateGetNameForIndex"),
              let stateResidency: StateResidency = symbol("IOReportStateGetResidency"),
              let simpleValue: SimpleValue = symbol("IOReportSimpleGetIntegerValue"),
              let cpu = copyChannels("CPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        if let energy = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() {
            mergeChannels(cpu, energy, nil)
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, cpu, &subscribed, 0, nil) else { return nil }

        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelGroup = channelGroup
        self.channelSubgroup = channelSubgroup
        self.channelName = channelName
        self.channelUnit = channelUnit
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.simpleValue = simpleValue
        self.subscription = subscription
        self.channels = cpu
        self.dvfsTables = Self.dvfsTables()
    }

    deinit {
        // The page's visibility gate creates a client per visit; the subscription must not leak.
        // Created by the "Create" rule, so it arrives with a +1 retain that Swift does not own.
        Unmanaged<AnyObject>.fromOpaque(subscription).release()
    }

    /// Frequency and power since the previous call. The first call only primes the baseline.
    public func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> FrequencyReading? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer {
            previous = current
            previousTime = now
        }
        guard let previous, let previousTime, now > previousTime,
              let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue(),
              let list = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary]
        else { return nil }

        var reading = FrequencyReading()
        var fastest: (max: Double, current: Double)?
        for channel in list {
            let group = channelGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let subgroup = channelSubgroup(channel)?.takeUnretainedValue() as String? ?? ""
            let name = channelName(channel)?.takeUnretainedValue() as String? ?? ""

            if group == "Energy Model", name == "GPU Energy" {
                let unit = channelUnit(channel)?.takeUnretainedValue() as String? ?? ""
                reading.gpuPowerWatts = FrequencyMath.watts(energy: Double(simpleValue(channel, 0)),
                                                            unit: unit, seconds: now - previousTime)
            }
            // Cluster channels repeat as complex/cluster and as _IDLE variants; one per cluster is enough.
            guard subgroup == "CPU Complex Performance States", !name.hasSuffix("_IDLE") else { continue }
            guard let cluster = cluster(of: channel), cluster.max > (fastest?.max ?? 0) else { continue }
            fastest = cluster
        }
        reading.cpuMaxHz = fastest?.max
        reading.cpuCurrentHz = fastest?.current
        return reading.isEmpty ? nil : reading
    }

    /// Residencies for one cluster, matched to the DVFS table with the same number of states.
    /// `DOWN` and `IDLE` are not frequencies, so they are dropped before matching.
    private func cluster(of channel: CFDictionary) -> (max: Double, current: Double)? {
        let count = Int(stateCount(channel))
        guard count > 0 else { return nil }
        var residencies: [Double] = []
        residencies.reserveCapacity(count)
        for index in 0..<count {
            let name = stateName(channel, Int32(index))?.takeUnretainedValue() as String? ?? ""
            guard !Self.nonFrequencyStates.contains(name) else { continue }
            residencies.append(Double(max(stateResidency(channel, Int32(index)), 0)))
        }
        guard let table = dvfsTables.first(where: { $0.count == residencies.count }), let peak = table.max() else { return nil }
        // A cluster parked for the whole interval ran no cycles, so 0 Hz is the honest answer.
        return (peak, FrequencyMath.weightedFrequency(residencies: residencies, frequencies: table) ?? 0)
    }

    private static let nonFrequencyStates: Set<String> = ["DOWN", "IDLE", "OFF", "NON_IDLE"]

    /// Every DVFS table the power manager publishes that is actually a frequency ladder, in hertz.
    ///
    /// Matching is by state count, because the table names (`voltage-states5-sram` and friends) do
    /// not say which device they belong to. Several published tables are not frequency ladders at
    /// all and decode into nonsense (tens of GHz); `isFrequencyLadder` drops them, so a garbage
    /// table can never win a count match.
    static func dvfsTables() -> [[Double]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var tables: [[Double]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let properties = Self.registryProperties(of: service) else { continue }
            for (key, value) in properties where key.hasPrefix("voltage-states") {
                guard let data = value as? Data else { continue }
                let states = FrequencyMath.normalizeToHertz(FrequencyMath.states(from: data))
                if FrequencyMath.isFrequencyLadder(states) { tables.append(states) }
            }
        }
        // Highest clock first, so the fastest cluster wins ties on state count.
        return tables.sorted { ($0.max() ?? 0) > ($1.max() ?? 0) }
    }

    private static func registryProperties(of entry: io_registry_entry_t) -> [String: Any]? {
        var dictionary: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &dictionary, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return dictionary?.takeRetainedValue() as? [String: Any]
    }
}
