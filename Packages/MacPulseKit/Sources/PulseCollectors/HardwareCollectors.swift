import Foundation
import IOKit

public struct GPUReading: Sendable, Equatable {
    /// Overall GPU busy %, as Activity Monitor's GPU History shows.
    public var utilizationPercent: Double
    public var rendererPercent: Double?
    /// System memory currently wired for the GPU (unified memory on Apple Silicon).
    public var memoryInUseBytes: UInt64?
}

/// GPU utilization from the public IORegistry `IOAccelerator` performance statistics.
public enum GPUCollector {
    public static func sample() -> GPUReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: GPUReading?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let stats, let reading = parse(stats), reading.utilizationPercent >= (best?.utilizationPercent ?? -1) {
                best = reading            // multiple GPUs (Intel + discrete): report the busiest
            }
        }
        return best
    }

    static func parse(_ stats: [String: Any]) -> GPUReading? {
        guard let device = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue else { return nil }
        return GPUReading(utilizationPercent: device,
                          rendererPercent: (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue,
                          memoryInUseBytes: (stats["In use system memory"] as? NSNumber)?.uint64Value)
    }
}

public struct PeripheralBattery: Sendable, Equatable, Identifiable {
    public var name: String
    public var percent: Int
    public var id: String { name }
}

/// Batteries of connected Bluetooth HID peripherals (keyboards, mice, trackpads) that publish
/// `BatteryPercent` in the IORegistry. AirPods use a private channel and are not covered.
public enum PeripheralBatteryCollector {
    public static func sample() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [PeripheralBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if let battery = parse(product: property("Product"), percent: property("BatteryPercent")) {
                result.append(battery)
            }
        }
        // One device can expose several services; keep one entry per name.
        var seen = Set<String>()
        return result.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }

    static func parse(product: Any?, percent: Any?) -> PeripheralBattery? {
        guard let name = product as? String, !name.isEmpty,
              let value = (percent as? NSNumber)?.intValue, (0...100).contains(value) else { return nil }
        return PeripheralBattery(name: name, percent: value)
    }
}
