import SwiftUI
import PulseCollectors
import PulseEngine

struct ProcessesView: View {
    let metrics: LiveMetrics
    /// Dashboard toolbar search.
    let search: String
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)]
    @State private var icons = IconCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader("Processes", subtitle: search.isEmpty ? "\(metrics.processes.count) processes"
                                                             : "\(rows.count) of \(metrics.processes.count) processes match “\(search)”")
                .padding([.horizontal, .top], 24)
            table
        }
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
            TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }
                .width(60)
            TableColumn("CPU %", value: \.cpuPercent) { Text(String(format: "%.1f", $0.cpuPercent)).monospacedDigit() }
                .width(70)
            TableColumn("Memory", value: \.memoryBytes) { Text(Format.memory($0.memoryBytes)).monospacedDigit() }
                .width(90)
            TableColumn("User", value: \.userSortKey) { Text($0.user ?? "–").foregroundStyle(.secondary) }
                .width(90)
            TableColumn("Started", value: \.startSortKey) { row in
                Text(row.startTime.map { $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened) } ?? "–")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(120)
        }
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
