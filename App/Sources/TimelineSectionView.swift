import SwiftUI
import PulseCore
import PulseEngine
import PulseStore

/// PRD §9: what changed, when — stored events merged with ones not yet flushed to disk.
struct TimelineSectionView: View {
    let metrics: LiveMetrics

    @State private var range: ChartRange = .hour
    /// Owned by the dashboard so other sections (Sensors → "View History") can open a filtered timeline.
    @Binding var category: TimelineCategory?
    @State private var stored: [TimelineEvent] = []
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Timeline", subtitle: "What changed on this Mac, and when.") {
                ChartRangePicker(range: $range, options: ChartRange.stored)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)
            HStack {
                Picker("Category", selection: $category) {
                    Text("All categories").tag(TimelineCategory?.none)
                    ForEach(TimelineCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                .fixedSize()
                Spacer()
                Text("\(events.count) events").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            if let error = metrics.historyError {
                Label("New events are not being saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if let loadError {
                ContentUnavailableView("Could not read history", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if events.isEmpty {
                ContentUnavailableView("No events", systemImage: "clock",
                                       description: Text("Nothing changed in this range."))
            } else {
                List(runs) { run in
                    EventRow(event: run.latest, repeats: run.count, runStarted: run.started)
                        .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .task(id: range) { await load() }
    }

    /// Stored events plus live ones still in the 30 s write buffer, newest first, de-duplicated by id.
    private var events: [TimelineEvent] {
        let cutoff = Date().addingTimeInterval(-range.rawValue)
        let storedIDs = Set(stored.map(\.id))
        let live = metrics.recentEvents.filter { $0.time >= cutoff && !storedIDs.contains($0.id) }
        return (live + stored)
            .filter { category == nil || $0.category == category }
            .sorted { $0.time > $1.time }
    }

    /// Consecutive events that say the same thing about the same metric, as one row.
    ///
    /// A process that stays busy is one fact; the log used to repeat it every time the reading
    /// re-armed, and the repetition buried the structural events — a memory-pressure change sat
    /// between two identical CPU lines and read like more of the same. Collapsing runs is a
    /// display decision: every event is still recorded, still exported, still counted in the
    /// header, and a filter or a narrower range shows them individually.
    private struct Run: Identifiable {
        let latest: TimelineEvent
        let started: Date?
        let count: Int
        var id: UUID { latest.id }
    }

    private var runs: [Run] {
        var runs: [Run] = []
        for event in events {
            // `events` is newest first, so the run's first element is its latest occurrence.
            if let last = runs.last, last.latest.category == event.category,
               last.latest.title == event.title, last.latest.severity == event.severity {
                runs[runs.count - 1] = Run(latest: last.latest, started: event.time, count: last.count + 1)
            } else {
                runs.append(Run(latest: event, started: nil, count: 1))
            }
        }
        return runs
    }

    private func load() async {
        guard let history = metrics.history else { stored = []; return }
        let from = Date().addingTimeInterval(-range.rawValue)
        do {
            stored = try await Task.detached { try history.events(from: from, to: Date(), limit: 2_000) }.value
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
