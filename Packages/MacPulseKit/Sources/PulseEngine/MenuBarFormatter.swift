import PulseCore
import PulseCollectors

/// Metrics the user can show in the menu bar (PRD §14).
public enum MenuBarItem: String, CaseIterable, Codable, Sendable {
    case cpu, memory, network, latency, battery, thermal
    /// CPU °C (private sensors, ADR 0002).
    case temperature
    case gpu

    public static let defaults: [MenuBarItem] = [.cpu, .memory, .network, .latency]
}

public struct MenuBarInputs: Sendable {
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var network: NetworkReading?
    public var networkHealth: NetworkHealthReading?
    public var battery: BatteryReading?
    public var thermal: ThermalState?
    public var cpuCelsius: Double?
    public var gpuPercent: Double?

    public init(cpu: CPUReading? = nil, memory: MemoryReading? = nil, network: NetworkReading? = nil,
                networkHealth: NetworkHealthReading? = nil, battery: BatteryReading? = nil, thermal: ThermalState? = nil,
                cpuCelsius: Double? = nil, gpuPercent: Double? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.networkHealth = networkHealth
        self.battery = battery
        self.thermal = thermal
        self.cpuCelsius = cpuCelsius
        self.gpuPercent = gpuPercent
    }
}

public enum MenuBarFormatter {
    /// PRD §5 Level 1 style, e.g. "CPU 21% | MEM 62% | ↓8.4M ↑1.2M | 18ms". Missing readings render as "--".
    /// Battery is omitted on Macs without one.
    public static func text(_ items: [MenuBarItem], _ inputs: MenuBarInputs) -> String {
        segments(items, inputs).map(\.text).joined(separator: separator)
    }

    public static let separator = " | "

    /// The rendered segments, in order, for callers that decorate each one (e.g. with an icon).
    public static func segments(_ items: [MenuBarItem], _ inputs: MenuBarInputs) -> [(item: MenuBarItem, text: String)] {
        items.compactMap { item in segment(item, inputs).map { (item, $0) } }
    }

    /// SF Symbol shown before an item's text when menu-bar icons are on.
    public static func symbol(for item: MenuBarItem) -> String {
        switch item {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .latency: "globe"
        case .battery: "battery.75percent"
        case .thermal, .temperature: "thermometer.medium"
        case .gpu: "square.stack.3d.up"
        }
    }

    static func segment(_ item: MenuBarItem, _ i: MenuBarInputs) -> String? {
        switch item {
        case .cpu: "CPU " + (i.cpu.map { percent($0.totalPercent) } ?? "--")
        case .memory: "MEM " + (i.memory.map { percent($0.usedPercent) } ?? "--")
        case .network: i.network.map { "↓\(rate($0.downBytesPerSec)) ↑\(rate($0.upBytesPerSec))" } ?? "↓-- ↑--"
        case .latency: latency(i.networkHealth)
        case .battery: i.battery.map { "BAT " + percent($0.percent) }
        case .thermal: i.thermal.map(thermalName) ?? "--"
        case .temperature: i.cpuCelsius.map { "\(Int($0.rounded()))°C" } ?? "--°C"
        case .gpu: "GPU " + (i.gpuPercent.map(percent) ?? "--")
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
