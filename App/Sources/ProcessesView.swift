import SwiftUI
import PulseCollectors
import PulseEngine

struct ProcessesView: View {
    let metrics: LiveMetrics
    /// Dashboard toolbar search.
    let search: String
    @State private var sortOrder: [KeyPathComparator<ProcessRow>]
    @State private var icons = IconCache()

    /// `initialSort` picks the column the table opens on, e.g. memory when the Concern is memory.
    init(metrics: LiveMetrics, search: String, initialSort: ProcessSort = .cpu) {
        self.metrics = metrics
        self.search = search
        _sortOrder = State(initialValue: [initialSort == .memory
            ? KeyPathComparator(\ProcessRow.memoryBytes, order: .reverse)
            : KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)])
    }

    var body: some View {
        table
            .scrollContentBackground(.hidden)
            .navigationSubtitle(search.isEmpty ? "\(metrics.processes.count) processes"
                                               : "\(rows.count) of \(metrics.processes.count) processes match “\(search)”")
        .onAppear(perform: metrics.processListAppeared)
        .onDisappear(perform: metrics.processListDisappeared)
    }

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
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
            .width(min: 180, ideal: 320)
            // Columns size to their content: a fixed width is a guess about one locale and one
            // text size, and both vary. Minimums keep the headers readable; ideals keep the
            // default layout close to what it was.
            TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }
                .width(min: 52, ideal: 60)
            TableColumn("CPU %", value: \.cpuPercent) { Text(Format.decimal($0.cpuPercent, places: 1)).monospacedDigit() }
                .width(min: 62, ideal: 70)
            TableColumn("Memory", value: \.memoryBytes) { Text(Format.memory($0.memoryBytes)).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("User", value: \.userSortKey) { Text($0.user ?? "").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 92, ideal: 110)   // fits the longest system account (_windowserver) at the window minimum
            TableColumn("Started", value: \.startSortKey) { row in
                Text(row.startTime.map(Self.started) ?? "")
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 96, ideal: 130)
        }
    }

    /// Today's processes show the clock; older ones show a numeric date. An abbreviated date
    /// ("26 Sep 2569 BE") plus a time overruns the column in calendars and locales wider than
    /// English — the user's own calendar is correct, the guessed column width was not.
    private static func started(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .numeric, time: .omitted)
    }

    private var rows: [ProcessRow] {
        let filtered = search.isEmpty
            ? metrics.processes
            : metrics.processes.filter { $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search }
        return filtered.sorted(using: sortOrder)
    }
}

private extension ProcessRow {
    var userSortKey: String { user ?? "" }
    var startSortKey: Date { startTime ?? .distantPast }
}
