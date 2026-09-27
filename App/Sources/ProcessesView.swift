import SwiftUI
import PulseCollectors
import PulseEngine

struct ProcessesView: View {
    let metrics: LiveMetrics
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)]
    @State private var icons = IconCache()

    var body: some View {
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
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .navigationTitle("Processes")
        .navigationSubtitle("\(metrics.processes.count) processes")
        .onAppear(perform: metrics.processListAppeared)
        .onDisappear(perform: metrics.processListDisappeared)
    }

    private var rows: [ProcessRow] {
        let filtered = search.isEmpty
            ? metrics.processes
            : metrics.processes.filter { $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search }
        return filtered.sorted(using: sortOrder)
    }
}

/// App icons for GUI processes, generic executable icon otherwise. Looked up once per PID.
@MainActor
private final class IconCache {
    private var cache: [Int32: NSImage] = [:]
    private let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for pid: Int32) -> NSImage {
        if let cached = cache[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? generic
        cache[pid] = icon
        return icon
    }
}
