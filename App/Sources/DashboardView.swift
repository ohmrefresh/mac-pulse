import SwiftUI
import PulseCore
import PulseEngine

enum DashboardSection: String, CaseIterable, Identifiable {
    // Sidebar order.
    case overview = "Overview"
    case performance = "Performance"
    case network = "Network"
    case processes = "Processes"
    case storage = "Storage"
    case battery = "Battery"
    case sensors = "Sensors"
    case timeline = "Timeline"
    case alerts = "Alerts"
    case developer = "Developer"

    var id: Self { self }

    /// Sidebar headings: live readings, what already happened, and tools.
    enum Group: String, CaseIterable, Identifiable {
        case monitor = "Monitor", history = "History", tools = "Tools"
        var id: Self { self }
    }

    var group: Group {
        switch self {
        case .timeline, .alerts: .history
        case .developer: .tools
        default: .monitor
        }
    }

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

    /// Sections that filter their own content by the toolbar search; typing anywhere else opens Processes.
    var ownsSearch: Bool { self == .timeline || self == .developer }

    var searchPrompt: String {
        switch self {
        case .timeline: "Search events"
        case .developer: "Filter containers, ports, processes"
        default: "Search processes"
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
    @State private var showDiagnostics = false
    /// Toolbar search. Timeline filters its events by it and Developer its containers and ports; from
    /// any other section typing jumps to Processes, which filters by it.
    @State private var search = ""
    @State private var timelineCategory: TimelineCategory?
    /// Column Processes opens on; the Overview's Concern banner sets it to memory for a memory Concern.
    @State private var processSort = ProcessSort.cpu

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(DashboardSection.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(DashboardSection.allCases.filter { $0.group == group }) { section in
                            sidebarRow(section)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top) { sidebarHeader }
            .background { shortcutButtons }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    SidebarStatus(metrics: metrics)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(metrics: metrics, runDiagnostics: { showDiagnostics = true },
                                             showProcesses: { sort in
                                                 processSort = sort
                                                 selection = .processes
                                             },
                                             showTimeline: { category in
                                                 timelineCategory = category
                                                 selection = .timeline
                                             })
                case .performance: PerformanceView(metrics: metrics, showMemoryTimeline: {
                    timelineCategory = .memory
                        selection = .timeline
                    })
                case .network: NetworkDetailView(metrics: metrics)
                case .processes: ProcessesView(metrics: metrics, search: search, initialSort: processSort)
                case .developer: DeveloperView(metrics: metrics, settings: settings, search: search)
                case .storage: StorageView(metrics: metrics)
                case .battery: BatteryView(metrics: metrics)
                case .sensors: SensorsView(metrics: metrics, settings: settings, showThermalHistory: {
                        timelineCategory = .thermal
                        selection = .timeline
                    })
                case .alerts: AlertsView(metrics: metrics, settings: settings, notifier: notifier,
                                         showTimeline: {
                                             timelineCategory = .alert
                                             selection = .timeline
                                         })
                case .timeline: TimelineSectionView(metrics: metrics, category: $timelineCategory, search: search)
                }
            }
            .navigationTitle((selection ?? .overview).rawValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.window)
            .toolbarBackground(Palette.window, for: .windowToolbar)
        }
        .searchable(text: $search, placement: .toolbar,
                    prompt: (selection ?? .overview).searchPrompt)
        .onChange(of: search) { _, query in
            if !query.isEmpty, selection?.ownsSearch != true { selection = .processes }
        }
        .onChange(of: selection) { old, new in
            // A banner-chosen sort lasts one visit; Processes otherwise opens on CPU.
            if old == .processes { processSort = .cpu }
            // An event or port query means nothing to a process list, and the reverse.
            if old?.ownsSearch == true || new?.ownsSearch == true { search = "" }
        }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(metrics: metrics) }
        .environment(\.temperatureUnit, settings.temperatureUnit)
        .frame(minWidth: 980, minHeight: 620)
    }

    private func sidebarRow(_ section: DashboardSection) -> some View {
        Label {
            HStack {
                Text(section.rawValue)
                Spacer(minLength: 4)
                switch section {
                case .processes where !metrics.processes.isEmpty:
                    Text("\(metrics.processes.count)").monospacedDigit().foregroundStyle(.secondary)
                case .alerts where !metrics.firingAlertIDs.isEmpty:
                    // Firing Alert Rules, in the most severe one's colour.
                    HealthBadge(level: metrics.worstFiringSeverity ?? .warning,
                                label: "\(metrics.firingAlertIDs.count)")
                        .monospacedDigit()
                        .accessibilityLabel("\(metrics.firingAlertIDs.count) firing")
                default:
                    EmptyView()
                }
            }
        } icon: {
            Image(systemName: section.symbol).foregroundStyle(section.style.tint)
        }
        .tag(section)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            AppLogo(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Pulse").font(.headline)
                Text(Format.macSummary(hasBattery: metrics.hasInternalBattery, processor: metrics.processorName))
                    .font(.caption).foregroundStyle(.secondary)
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

/// Above Settings: how long the Mac has been up, and whether anything needs attention — the Concern's
/// headline with its Health Level mark, from any section.
private struct SidebarStatus: View {
    let metrics: LiveMetrics

    var body: some View {
        let concern = metrics.concern
        HStack(spacing: 6) {
            SeverityMark(level: concern?.level ?? .healthy, font: .caption2)
            // Uptime ticks by the minute; the rest follows the observed Concern.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(line(concern)).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func line(_ concern: Concern?) -> String {
        // Not "All healthy": a signal with no reading yet is not known to be healthy.
        let state = concern.map { Format.concernTitle($0.signal, offline: metrics.networkHealth?.connectivity == .offline) }
            ?? "No concerns"
        guard let uptime = metrics.uptime else { return state }
        return "Uptime \(Format.uptime(uptime)) · \(state)"
    }
}
