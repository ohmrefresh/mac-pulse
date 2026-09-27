import SwiftUI
import PulseEngine

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case performance = "Performance"
    case network = "Network"
    case processes = "Processes"
    case storage = "Storage"
    case battery = "Battery"
    case sensors = "Sensors"
    case timeline = "Timeline"
    case alerts = "Alerts"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "house"
        case .performance: "cpu"
        case .network: "arrow.up.arrow.down"
        case .processes: "list.bullet.rectangle"
        case .storage: "internaldrive"
        case .battery: "battery.75percent"
        case .sensors: "thermometer.medium"
        case .timeline: "clock"
        case .alerts: "bell"
        }
    }

    /// PRD §17: ⌘1–⌘4.
    var shortcut: KeyEquivalent? {
        switch self {
        case .overview: "1"
        case .performance: "2"
        case .network: "3"
        case .processes: "4"
        default: nil
        }
    }
}

struct DashboardView: View {
    let metrics: LiveMetrics
    let settings: AppSettings
    let notifier: AlertNotifier
    @State private var selection: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .background { shortcutButtons }
            .safeAreaInset(edge: .bottom) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.borderless)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(metrics: metrics)
            case .performance: PerformanceView(metrics: metrics)
            case .network: NetworkDetailView(metrics: metrics)
            case .processes: ProcessesView(metrics: metrics)
            case .storage: StorageView(metrics: metrics)
            case .battery: BatteryView(metrics: metrics)
            case .sensors: SensorsView(metrics: metrics)
            case .alerts: AlertsView(metrics: metrics, settings: settings, notifier: notifier)
            case .timeline:
                // Need persistent history (PulseStore) — v1.0 / Phase 2.
                ContentUnavailableView(selection?.rawValue ?? "", systemImage: selection?.symbol ?? "clock",
                                       description: Text("Arrives with history in v1.0."))
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var shortcutButtons: some View {
        Group {
            ForEach(DashboardSection.allCases.filter { $0.shortcut != nil }) { section in
                Button(section.rawValue) { selection = section }
                    .keyboardShortcut(section.shortcut!, modifiers: .command)
            }
            // PRD §17 ⌘K search. macOS 14 cannot focus a search field programmatically
            // (`searchFocused` is macOS 15+), so this opens Processes, whose search is in the toolbar.
            Button("Search") { selection = .processes }
                .keyboardShortcut("k", modifiers: .command)
        }
        .hidden()
    }
}
