import PulseCore
import PulseCollectors

/// Metrics the user can show in the menu bar (PRD §14). Temperature is thermal state in v1.0.
public enum MenuBarItem: String, CaseIterable, Codable, Sendable {
    case cpu, memory, network, latency, battery, thermal

    public static let defaults: [MenuBarItem] = [.cpu, .memory, .network, .latency]
}

public struct MenuBarInputs: Sendable {
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var network: NetworkReading?
    public var networkHealth: NetworkHealthReading?
    public var battery: BatteryReading?
    public var thermal: ThermalState?

    public init(cpu: CPUReading? = nil, memory: MemoryReading? = nil, network: NetworkReading? = nil,
                networkHealth: NetworkHealthReading? = nil, battery: BatteryReading? = nil, thermal: ThermalState? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.networkHealth = networkHealth
        self.battery = battery
        self.thermal = thermal
    }
}

public enum MenuBarFormatter {
    /// PRD §5 Level 1 style, e.g. "CPU 21% | MEM 62% | ↓8.4M ↑1.2M | 18ms". Missing readings render as "--".
    /// Battery is omitted on Macs without one.
    public static func text(_ items: [MenuBarItem], _ inputs: MenuBarInputs) -> String {
        items.compactMap { segment($0, inputs) }.joined(separator: " | ")
    }

    /// Longest string each item can render, for sizing a fixed-width status item.
    public static func widestText(_ items: [MenuBarItem]) -> String {
        items.map { item in
            switch item {
            case .cpu: "CPU 100%"
            case .memory: "MEM 100%"
            case .network: "↓999M ↑999M"
            case .latency: "9999ms"
            case .battery: "BAT 100%"
            case .thermal: "Critical"
            }
        }.joined(separator: " | ")
    }

    static func segment(_ item: MenuBarItem, _ i: MenuBarInputs) -> String? {
        switch item {
        case .cpu: "CPU " + (i.cpu.map { percent($0.totalPercent) } ?? "--")
        case .memory: "MEM " + (i.memory.map { percent($0.usedPercent) } ?? "--")
        case .network: i.network.map { "↓\(rate($0.downBytesPerSec)) ↑\(rate($0.upBytesPerSec))" } ?? "↓-- ↑--"
        case .latency: latency(i.networkHealth)
        case .battery: i.battery.map { "BAT " + percent($0.percent) }
        case .thermal: i.thermal.map(thermalName) ?? "--"
        }
    }

    /// Internet round trip, "Offline" without a route, "--" before the first probe or on timeout.
    public static func latency(_ reading: NetworkHealthReading?) -> String {
        guard let reading else { return "--" }
        if reading.connectivity == .offline { return "Offline" }
        guard let ms = reading.internet?.latencyMs else { return "--" }
        return "\(Int(ms.rounded()))ms"
    }

    /// Compact bytes/second: "0K", "320K", "8.4M", "1.2G". One decimal only below 10.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let units: [(Double, String)] = [(1e9, "G"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where bytesPerSecond >= scale {
            let value = bytesPerSecond / scale
            return value < 10 ? "\((value * 10).rounded() / 10)\(suffix)" : "\(Int(value.rounded()))\(suffix)"
        }
        return "0K"
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private static func thermalName(_ state: ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
}
