import Foundation
import IOKit
import IOKit.ps

public struct BatteryReading: Sendable, Equatable {
    public var percent: Double
    public var isCharging: Bool
    public var onACPower: Bool
    /// Minutes; nil while macOS is still estimating or when on AC and not charging.
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Full-charge capacity as a percentage of design capacity.
    public var maximumCapacityPercent: Double?

    public init(percent: Double, isCharging: Bool, onACPower: Bool, minutesRemaining: Int?,
                cycleCount: Int?, maximumCapacityPercent: Double?) {
        self.percent = percent
        self.isCharging = isCharging
        self.onACPower = onACPower
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.maximumCapacityPercent = maximumCapacityPercent
    }
}

public struct BatteryCollector: Sendable {
    public init() {}

    /// Nil on Macs without an internal battery.
    public func sample() -> BatteryReading? {
        guard var reading = Self.powerSourceReading() else { return nil }
        let health = Self.smartBatteryHealth()
        reading.cycleCount = health.cycleCount
        reading.maximumCapacityPercent = health.maximumCapacityPercent
        return reading
    }

    static func powerSourceReading() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let reading = parse(description) else { continue }
            return reading
        }
        return nil
    }

    static func parse(_ description: [String: Any]) -> BatteryReading? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let minutes = (description[minutesKey] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        return BatteryReading(
            percent: Double(current) / Double(max) * 100,
            isCharging: charging,
            onACPower: onAC,
            minutesRemaining: (onAC && !charging) ? nil : minutes,
            cycleCount: nil,
            maximumCapacityPercent: nil
        )
    }

    static func smartBatteryHealth() -> (cycleCount: Int?, maximumCapacityPercent: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        let design = property("DesignCapacity")
        let rawMax = property("AppleRawMaxCapacity")
        // New batteries can exceed design capacity; System Settings caps the figure at 100%.
        let percent = (design.flatMap { $0 > 0 ? $0 : nil }).flatMap { d in rawMax.map { min(Double($0) / Double(d) * 100, 100) } }
        return (property("CycleCount"), percent)
    }
}
