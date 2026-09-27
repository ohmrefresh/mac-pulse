import AppKit
import Observation
import ServiceManagement
import PulseCore
import PulseEngine

/// User preferences (PRD §14), persisted in UserDefaults. Setters push changes to the running engine.
@MainActor
@Observable
final class AppSettings {
    static let samplingChoices: [TimeInterval] = [1, 2, 5]

    var menuBarItems: [MenuBarItem] {
        didSet { save(menuBarItems.map(\.rawValue), .menuBarItems); onMenuBarChange?() }
    }

    var samplingInterval: TimeInterval {
        didSet { save(samplingInterval, .samplingInterval); metrics.setSamplingInterval(samplingInterval) }
    }

    var showDockIcon: Bool {
        didSet { save(showDockIcon, .showDockIcon); applyActivationPolicy() }
    }

    var pingTarget: String {
        didSet { save(pingTarget, .pingTarget); pushNetworkConfig() }
    }

    var latencyWarningMs: Double { didSet { save(latencyWarningMs, .latencyWarningMs); pushNetworkConfig() } }
    var latencyCriticalMs: Double { didSet { save(latencyCriticalMs, .latencyCriticalMs); pushNetworkConfig() } }
    var lossWarningPercent: Double { didSet { save(lossWarningPercent, .lossWarningPercent); pushNetworkConfig() } }
    var lossCriticalPercent: Double { didSet { save(lossCriticalPercent, .lossCriticalPercent); pushNetworkConfig() } }

    /// Last launch-at-login error, shown in Settings instead of failing silently.
    private(set) var loginItemError: String?

    @ObservationIgnored var onMenuBarChange: (() -> Void)?
    @ObservationIgnored private let metrics: LiveMetrics
    @ObservationIgnored private let defaults: UserDefaults

    init(metrics: LiveMetrics, defaults: UserDefaults = .standard) {
        self.metrics = metrics
        self.defaults = defaults
        let n = NetworkThresholds()
        menuBarItems = (defaults.stringArray(forKey: Key.menuBarItems.rawValue)?.compactMap(MenuBarItem.init(rawValue:)))
            ?? MenuBarItem.defaults
        samplingInterval = defaults.object(forKey: Key.samplingInterval.rawValue) as? TimeInterval ?? 1
        showDockIcon = defaults.bool(forKey: Key.showDockIcon.rawValue)
        pingTarget = defaults.string(forKey: Key.pingTarget.rawValue) ?? "1.1.1.1"
        latencyWarningMs = defaults.object(forKey: Key.latencyWarningMs.rawValue) as? Double ?? n.latencyMs.warning
        latencyCriticalMs = defaults.object(forKey: Key.latencyCriticalMs.rawValue) as? Double ?? n.latencyMs.critical
        lossWarningPercent = defaults.object(forKey: Key.lossWarningPercent.rawValue) as? Double ?? n.packetLossPercent.warning
        lossCriticalPercent = defaults.object(forKey: Key.lossCriticalPercent.rawValue) as? Double ?? n.packetLossPercent.critical
    }

    /// Push persisted values into the engine at launch (didSet does not run during init).
    func applyAtLaunch() {
        metrics.setSamplingInterval(samplingInterval)
        pushNetworkConfig()
        applyActivationPolicy()
        enableLaunchAtLoginOnFirstRun()
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
        }
    }

    /// Decision 10: on by default. Only for installed copies, so dev builds in DerivedData never register.
    private func enableLaunchAtLoginOnFirstRun() {
        guard !defaults.bool(forKey: Key.didOfferLaunchAtLogin.rawValue),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        defaults.set(true, forKey: Key.didOfferLaunchAtLogin.rawValue)
        launchAtLogin = true
    }

    // MARK: Helpers

    func isEnabled(_ item: MenuBarItem) -> Bool { menuBarItems.contains(item) }

    /// Keeps PRD order regardless of toggle order.
    func setEnabled(_ item: MenuBarItem, _ enabled: Bool) {
        var set = Set(menuBarItems)
        if enabled { set.insert(item) } else { set.remove(item) }
        menuBarItems = MenuBarItem.allCases.filter(set.contains)
    }

    var pingTargetIsValid: Bool {
        var address = in_addr()
        return inet_pton(AF_INET, pingTarget, &address) == 1
    }

    private func pushNetworkConfig() {
        // An invalid host would read as 100% loss; keep probing the last valid one until it's fixed.
        guard pingTargetIsValid else { return }
        // Threshold's precondition requires warning ≤ critical; clamp rather than crash on mid-edit values.
        let thresholds = NetworkThresholds(
            latencyMs: Threshold(warning: min(latencyWarningMs, latencyCriticalMs), critical: latencyCriticalMs),
            packetLossPercent: Threshold(warning: min(lossWarningPercent, lossCriticalPercent), critical: lossCriticalPercent))
        metrics.configureNetwork(internetTarget: pingTarget, thresholds: thresholds)
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private enum Key: String {
        case menuBarItems, samplingInterval, showDockIcon, pingTarget
        case latencyWarningMs, latencyCriticalMs, lossWarningPercent, lossCriticalPercent
        case didOfferLaunchAtLogin
    }

    private func save(_ value: Any, _ key: Key) { defaults.set(value, forKey: key.rawValue) }
}
