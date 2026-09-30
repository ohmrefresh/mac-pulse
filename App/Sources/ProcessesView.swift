import SwiftUI
import PulseCollectors
import PulseEngine

/// Which processes the list shows: everything, the current user's, or the rest.
enum ProcessScope: String, CaseIterable {
    case all = "All", mine = "My apps", system = "System"

    /// System is everything that is not the current user's, including rows whose owner could not
    /// be resolved: an unknown owner is not known to be the user.
    func includes(_ row: ProcessRow, currentUser: String) -> Bool {
        switch self {
        case .all: true
        case .mine: row.user == currentUser
        case .system: row.user != currentUser
        }
    }
}

struct ProcessesView: View {
    let metrics: LiveMetrics
    /// Dashboard toolbar search.
    let search: String
    @State private var sortOrder: [KeyPathComparator<ProcessRow>]
    @State private var scope = ProcessScope.all
    @State private var icons = IconCache()
    private let currentUser = NSUserName()

    /// `initialSort` picks the column the table opens on, e.g. memory when the Concern is memory.
    init(metrics: LiveMetrics, search: String, initialSort: ProcessSort = .cpu) {
        self.metrics = metrics
        self.search = search
        _sortOrder = State(initialValue: [initialSort == .memory
            ? KeyPathComparator(\ProcessRow.memoryBytes, order: .reverse)
            : KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)])
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            table(rows)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer(shown: rows.count)
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                LivePill(interval: metrics.samplingInterval)
                Picker("Show", selection: $scope) {
                    ForEach(ProcessScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("All processes, the ones you own, or the system's")
            }
        }
        .onAppear(perform: metrics.processListAppeared)
        .onDisappear(perform: metrics.processListDisappeared)
    }

    /// "608 processes · CPU 38% · 20.1 GB memory"; a figure not read yet is left out.
    private var subtitle: String {
        [
            "\(metrics.processes.count) processes",
            metrics.cpu.map { "CPU \(Format.percent($0.totalPercent))" },
            metrics.memory.map { "\(Format.gigabytes($0.usedBytes, places: 1)) GB memory" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func table(_ rows: [ProcessRow]) -> some View {
        // Read once per refresh, not once per cell.
        let now = Date()
        let totalRAM = metrics.memory.map { Double(max($0.totalBytes, 1)) }
        return Table(rows, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: icons.icon(for: row.pid))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(row.name).lineLimit(1)
                    if row.isPrivileged {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("System process — refreshed every 5 s")
                    }
                }
            }
            // Name takes whatever the sized columns leave, but never collapses below a floor:
            // it is the column the user reads first.
            .width(min: 180, ideal: 300)
            // Columns size to their content: a fixed width is a guess about one locale and one
            // text size, and both vary. Minimums keep the headers readable; ideals keep the
            // default layout close to what it was.
            TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 52, ideal: 60)
            TableColumn("CPU", value: \.cpuPercent) { row in
                // The bar is one core's share, so a process above one core fills it; the figure
                // keeps the real value.
                HStack(spacing: 8) {
                    CellMeter(fraction: row.cpuPercent / 100, tint: MetricStyle.cpu.tint)
                    Text("\(Format.decimal(row.cpuPercent, places: 1))%")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 118, ideal: 130)
            TableColumn("Memory", value: \.memoryBytes) { row in
                HStack(spacing: 8) {
                    if let totalRAM {
                        CellMeter(fraction: Double(row.memoryBytes) / totalRAM, tint: MetricStyle.memory.tint)
                    }
                    Text(Format.memory(row.memoryBytes))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 128, ideal: 140)
            TableColumn("User", value: \.userSortKey) { Text($0.user ?? "").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 92, ideal: 110)   // fits the longest system account (_windowserver) at the window minimum
            TableColumn("Running", value: \.runningSortKey) { row in
                Text(row.startTime.map { Format.running(since: $0, now: now) } ?? "")
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.startTime.map { "Started \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
            .width(min: 70, ideal: 80)
        }
    }

    private func footer(shown: Int) -> some View {
        HStack(spacing: 12) {
            Text("Showing \(shown) of \(metrics.processes.count)").monospacedDigit()
            Spacer(minLength: 12)
            Text(legend).lineLimit(1).truncationMode(.head)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// What the bars measure. The memory half needs the Mac's RAM, so it waits for a reading.
    private var legend: String {
        let cpu = "CPU bar = share of one core"
        guard let memory = metrics.memory else { return cpu }
        return "\(cpu) · Memory bar = share of \(Format.gigabytes(memory.totalBytes, places: 0)) GB"
    }

    private var rows: [ProcessRow] {
        let filtered = metrics.processes.filter { row in
            scope.includes(row, currentUser: currentUser)
                && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search) || String(row.pid) == search)
        }
        return filtered.sorted(using: sortOrder)
    }
}

private extension ProcessRow {
    var userSortKey: String { user ?? "" }
    /// Ascending is shortest-running first; an unknown start sorts after every known one.
    var runningSortKey: Double { startTime.map { -$0.timeIntervalSinceReferenceDate } ?? .infinity }
}
