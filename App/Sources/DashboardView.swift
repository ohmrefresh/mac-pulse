import SwiftUI
import PulseEngine

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case performance = "Performance"
    case network = "Network"
    case processes = "Processes"
    case developer = "Developer"
    case storage = "Storage"
    case battery = "Battery"
    case sensors = "Sensors"
    case timeline = "Timeline"
    case alerts = "Alerts"

    var id: Self { self }

    var style: MetricStyle {
        switch self {
        case .overview: .internet
        case .performance: .cpu
        case .network: .network
        case .processes: .processes
        case .developer: .developer
        case .storage: .disk
        case .battery: .battery
        case .sensors: .temperature
        case .timeline: .timeline
        case .alerts: .alerts
        }
    }

    var symbol: String { self == .overview ? "house" : style.symbol }

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
    @State private var showDiagnostics = false
    /// Toolbar search; typing jumps to Processes, which filters by it.
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.rawValue)
                } icon: {
                    Image(systemName: section.symbol).foregroundStyle(section.style.tint)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top) { sidebarHeader }
            .background { shortcutButtons }
            .safeAreaInset(edge: .bottom) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.borderless)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(metrics: metrics, runDiagnostics: { showDiagnostics = true },
                                         showTimeline: { selection = .timeline })
            case .performance: PerformanceView(metrics: metrics)
            case .network: NetworkDetailView(metrics: metrics)
            case .processes: ProcessesView(metrics: metrics, search: search)
            case .developer: DeveloperView(metrics: metrics, settings: settings)
            case .storage: StorageView(metrics: metrics)
            case .battery: BatteryView(metrics: metrics)
            case .sensors: SensorsView(metrics: metrics)
            case .alerts: AlertsView(metrics: metrics, settings: settings, notifier: notifier)
            case .timeline: TimelineSectionView(metrics: metrics)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .onChange(of: search) { _, query in
            if !query.isEmpty { selection = .processes }
        }
        .modifier(HiddenToolbarTitle())
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(metrics: metrics) }
        .frame(minWidth: 980, minHeight: 620)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            AppLogo(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Pulse").font(.headline)
                Text("System Monitoring for macOS").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var shortcutButtons: some View {
        Group {
            ForEach(DashboardSection.allCases.filter { $0.shortcut != nil }) { section in
                Button(section.rawValue) { selection = section }
                    .keyboardShortcut(section.shortcut!, modifiers: .command)
            }
            // PRD §17 ⌘R from any section.
            Button("Run Diagnostics") { showDiagnostics = true }
                .keyboardShortcut("r", modifiers: .command)
            // PRD §17 ⌘K search. macOS 14 cannot focus a search field programmatically
            // (`searchFocused` is macOS 15+), so this opens Processes, which the toolbar search filters.
            Button("Search") { selection = .processes }
                .keyboardShortcut("k", modifiers: .command)
        }
        .hidden()
    }
}

/// Sections draw their own large titles. macOS 15 can drop the toolbar title; on 14 AppKit's
/// `titleVisibility = .hidden` (set on the window) is the only lever.
private struct HiddenToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
