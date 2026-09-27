import SwiftUI
import PulseCore
import PulseEngine
import PulseStore

/// PRD §9: what changed, when — stored events merged with ones not yet flushed to disk.
struct TimelineSectionView: View {
    let metrics: LiveMetrics

    enum Range: TimeInterval, CaseIterable, Identifiable {
        case hour = 3_600, sixHours = 21_600, day = 86_400, week = 604_800, month = 2_592_000
        var id: Self { self }
        var label: String {
            switch self {
            case .hour: "1 h"
            case .sixHours: "6 h"
            case .day: "24 h"
            case .week: "7 d"
            case .month: "30 d"
            }
        }
    }

    @State private var range: Range = .hour
    /// Owned by the dashboard so other sections (Sensors → "View History") can open a filtered timeline.
    @Binding var category: TimelineCategory?
    @State private var stored: [TimelineEvent] = []
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Timeline", subtitle: "What changed on this Mac, and when.")
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 8)
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
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
                List(events) { EventRow(event: $0).padding(.vertical, 2) }
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
