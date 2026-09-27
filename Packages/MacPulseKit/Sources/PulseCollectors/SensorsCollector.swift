import Foundation
import IOKit

// ADR 0002: temperatures and fans come from private interfaces. Everything here fails soft —
// a missing symbol or a refused call yields an empty reading, never a crash or a made-up value.

public struct TemperatureSensor: Sendable, Equatable, Identifiable {
    public var name: String
    public var celsius: Double
    public var id: String { name }
}

public struct FanReading: Sendable, Equatable, Identifiable {
    public var index: Int
    public var rpm: Double
    public var minRPM: Double?
    public var maxRPM: Double?
    public var id: Int { index }
}

public struct SensorsReading: Sendable, Equatable {
    /// Hottest CPU die sensor.
    public var cpuCelsius: Double?
    public var ssdCelsius: Double?
    public var batteryCelsius: Double?
    /// All plausible sensors, averaged per name, sorted by name.
    public var sensors: [TemperatureSensor]
    public var fans: [FanReading]

    public var isEmpty: Bool { sensors.isEmpty && fans.isEmpty }

    public init(cpuCelsius: Double?, ssdCelsius: Double?, batteryCelsius: Double?, sensors: [TemperatureSensor], fans: [FanReading]) {
        self.cpuCelsius = cpuCelsius
        self.ssdCelsius = ssdCelsius
        self.batteryCelsius = batteryCelsius
        self.sensors = sensors
        self.fans = fans
    }
}

public final class SensorsCollector: @unchecked Sendable {
    // @unchecked: the HID service cache and the SMC connection are mutable and guarded by `lock`.
    private let hid: HIDTemperatures?
    private let lock = NSLock()
    private var smc: SMCConnection?
    private var smcFailed = false

    public init() {
        hid = HIDTemperatures()
    }

    public func sample() -> SensorsReading {
        lock.lock()
        let raw = hid?.read() ?? []
        lock.unlock()
        let sensors = Self.group(raw)
        return SensorsReading(cpuCelsius: sensors.filter { $0.name.contains("tdie") }.map(\.celsius).max(),
                              ssdCelsius: sensors.first { $0.name.hasPrefix("NAND") }?.celsius,
                              batteryCelsius: sensors.first { $0.name.localizedCaseInsensitiveContains("gas gauge") }?.celsius,
                              sensors: sensors, fans: fans())
    }

    private func fans() -> [FanReading] {
        lock.lock()
        defer { lock.unlock() }
        if smc == nil && !smcFailed {
            smc = SMCConnection()
            smcFailed = smc == nil
        }
        guard let smc, let count = smc.readUInt8("FNum") else { return [] }
        return (0..<Int(count)).compactMap { i in
            smc.readFloat("F\(i)Ac").map { FanReading(index: i, rpm: max($0, 0), minRPM: smc.readFloat("F\(i)Mn"), maxRPM: smc.readFloat("F\(i)Mx")) }
        }
    }

    /// Drops implausible values (some PMU sensors report e.g. −9201) and averages duplicate names.
    static func group(_ raw: [(String, Double)]) -> [TemperatureSensor] {
        var sums: [String: (total: Double, count: Int)] = [:]
        for (name, value) in raw where (-20...130).contains(value) {
            let current = sums[name] ?? (0, 0)
            sums[name] = (current.total + value, current.count + 1)
        }
        return sums.map { TemperatureSensor(name: $0.key, celsius: $0.value.total / Double($0.value.count)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Private `IOHIDEventSystemClient` temperature sensors, resolved at runtime.
final class HIDTemperatures {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15            // kIOHIDEventTypeTemperature
    private let client: AnyObject
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let getFloat: GetFloat

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = symbol("IOHIDEventSystemClientCreate", Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", GetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Apple vendor usage page, temperature sensor usage.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    /// Sensor services and their names, resolved once (the expensive part) and refreshed rarely.
    private var services: [(name: String, service: AnyObject)] = []
    private var resolvedAt: Date = .distantPast
    private static let refreshServices: TimeInterval = 600

    func read(now: Date = Date()) -> [(String, Double)] {
        if services.isEmpty || now.timeIntervalSince(resolvedAt) > Self.refreshServices {
            let all = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
            // Each event read is an IPC round trip (~1 ms). Most names repeat ~3× with near-identical
            // values, and "tdev" sensors always read garbage, so keep one service per useful name.
            var seen = Set<String>()
            services = all.compactMap { service in
                guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                      !name.contains("tdev"), seen.insert(name).inserted else { return nil }
                return (name, service)
            }
            resolvedAt = now
        }
        return services.compactMap { entry in
            guard let event = copyEvent(entry.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return (entry.name, getFloat(event, Int32(Self.temperatureEvent << 16)))
        }
    }
}

/// Minimal read-only AppleSMC client (private user-client protocol, selector 2).
final class SMCConnection {
    /// Mirrors the kernel's SMCKeyData_t (80 bytes). Explicit padding keeps Swift from packing
    /// following fields into KeyInfo's tail, which C does not do.
    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyData {
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9
    private var connection: io_connect_t = 0

    init?() {
        guard MemoryLayout<KeyData>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    func readUInt8(_ key: String) -> UInt8? {
        guard let (type, bytes) = read(key), type == "ui8 ", let first = bytes.first else { return nil }
        return first
    }

    /// Apple Silicon reports fan speeds as little-endian `flt`.
    func readFloat(_ key: String) -> Double? {
        guard let (type, bytes) = read(key), type == "flt ", bytes.count >= 4 else { return nil }
        let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Double(Float(bitPattern: raw))
    }

    private func read(_ key: String) -> (String, [UInt8])? {
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var input = KeyData()
        input.key = code
        input.command = Self.readKeyInfo
        guard let info = call(&input) else { return nil }
        input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.command = Self.readBytes
        guard let output = call(&input) else { return nil }
        let t = info.keyInfo.dataType
        let type = String(decoding: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xff) }, as: UTF8.self)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.keyInfo.dataSize, 32)))) }
        return (type, bytes)
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }
}
