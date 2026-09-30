import SwiftUI
import PulseCore
import PulseEngine
import PulseStore

/// PRD §9: what changed, when — stored events merged with ones not yet flushed to disk, grouped into
/// Episodes (CONTEXT.md). After mock_v2: a summary card with category chips and a density strip, then
/// the rows by day.
struct TimelineSectionView: View {
    let metrics: LiveMetrics

    @State private var range: ChartRange = .hour
    /// Owned by the dashboard so other sections (Sensors → "View History") can open a filtered timeline.
    @Binding var category: TimelineCategory?
    /// The dashboard's toolbar search. Filters rows, never events: a query that matched an Episode's
    /// opening event but not its recovery must not turn it into an ongoing one.
    let search: String
    @State private var stored: [TimelineEvent] = []
    @State private var loadError: String?

    var body: some View {
        // Ticks each minute so the range cutoff, the strip's "now" and the Today/Yesterday headings
        // move on past midnight without waiting for a new event.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            page(now: context.date)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ChartRangePicker(range: $range, options: ChartRange.stored) }
        }
        .task(id: range) { await load() }
    }

    private func page(now: Date) -> some View {
        let inRange = events(now: now)
        let shown = inRange.filter { category == nil || $0.category == category }
        let rows = TimelineEpisodes.group(shown)
        let visible = rows.filter(matchesSearch)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = metrics.historyError {
                    NoticeBanner(level: .critical, symbol: "exclamationmark.triangle.fill",
                                 title: "New events are not being saved", detail: error)
                }
                summaryCard(inRange: inRange, shown: shown, rows: rows, now: now)
                listCard(visible: visible, rows: rows, eventCount: shown.count, now: now)
            }
            .padding(24)
        }
    }

    /// Stored events plus live ones still in the 30 s write buffer, newest first, de-duplicated by id.
    /// The cutoff applies to both: stored ones were read at load time and age out as `now` moves.
    private func events(now: Date) -> [TimelineEvent] {
        let cutoff = now.addingTimeInterval(-range.rawValue)
        let storedIDs = Set(stored.map(\.id))
        let live = metrics.recentEvents.filter { !storedIDs.contains($0.id) }
        return (live + stored).filter { $0.time >= cutoff }.sorted { $0.time > $1.time }
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matchesSearch(_ row: TimelineRow) -> Bool {
        guard !query.isEmpty else { return true }
        return [row.event.title, row.event.detail, row.end?.title, row.end?.detail]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    // MARK: Summary

    private func summaryCard(inRange: [TimelineEvent], shown: [TimelineEvent], rows: [TimelineRow], now: Date) -> some View {
        let ongoing = rows.filter(\.isOngoing).count
        let counts = Dictionary(grouping: inRange, by: \.category).mapValues(\.count)
        let summary = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(range.spanName).font(.headline)
            Text("\(shown.count) \(shown.count == 1 ? "event" : "events") · \(ongoing) ongoing")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        let chips = HStack(spacing: 6) {
            CategoryChip(name: "All", count: inRange.count, style: nil, isSelected: category == nil) { category = nil }
            ForEach(TimelineCategory.allCases.filter { counts[$0] != nil }, id: \.self) { c in
                CategoryChip(name: c.displayName, count: counts[c] ?? 0, style: c.style, isSelected: category == c) {
                    category = c
                }
            }
        }
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    summary
                    Spacer(minLength: 12)
                    chips
                }
                VStack(alignment: .leading, spacing: 8) {
                    summary
                    ScrollView(.horizontal, showsIndicators: false) { chips }
                }
            }
            DensityStrip(events: shown, range: range.rawValue, now: now)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: List

    private struct Day: Identifiable {
        let start: Date
        var rows: [TimelineRow]
        var id: Date { start }
    }

    /// Consecutive rows by the day of their latest activity. Rows arrive newest-first by that time,
    /// so each day is one contiguous run and the order is kept as given.
    private func days(_ rows: [TimelineRow]) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for row in rows {
            let start = calendar.startOfDay(for: row.lastTime)
            if days.last?.start == start { days[days.count - 1].rows.append(row) } else { days.append(Day(start: start, rows: [row])) }
        }
        return days
    }

    @ViewBuilder
    private func listCard(visible: [TimelineRow], rows: [TimelineRow], eventCount: Int, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let loadError {
                ContentUnavailableView("Could not read history", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if rows.isEmpty {
                InlineEmpty("Nothing changed in this range.")
            } else if visible.isEmpty {
                InlineEmpty("No events match “\(query)”.")
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(days(visible)) { day in
                        DayHeading(title: Format.dayHeading(day.start, now: now))
                        ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, row in
                            TimelineRowView(row: row, day: day.start, shaded: !index.isMultiple(of: 2))
                        }
                    }
                }
                footer(visible: visible.count, rows: rows.count, events: eventCount)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private func footer(visible: Int, rows: Int, events: Int) -> some View {
        let line: String? = if !query.isEmpty {
            "\(visible) of \(rows) rows match “\(query)”"
        } else if rows < events {
            "\(events) events in \(rows) rows · Episodes and repeats are grouped"
        } else {
            nil
        }
        if let line {
            Divider()
            Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
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

/// A filter chip: name and count, outlined in the category's tint and filled while selected.
private struct CategoryChip: View {
    let name: String
    let count: Int
    /// Nil for "All", which is neutral.
    let style: MetricStyle?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let tint = style?.tint ?? .secondary
        Button(action: action) {
            Text("\(name) · \(count)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(style.map { $0.tint.readableInk(on: .card, minimum: 4.5) } ?? Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(tint.opacity(isSelected ? 0.2 : 0), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(isSelected ? 0.6 : 0.35), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(name), \(count) events")
    }
}

/// One tick per event across the range, in its category's tint, with a few clock labels below.
private struct DensityStrip: View {
    let events: [TimelineEvent]
    let range: TimeInterval
    let now: Date

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let start = now.addingTimeInterval(-range)
                // One path per category, so a full 30 days is a handful of fills rather than thousands.
                for (category, group) in Dictionary(grouping: events, by: \.category) {
                    var path = Path()
                    for event in group {
                        let fraction = event.time.timeIntervalSince(start) / range
                        guard (0...1).contains(fraction) else { continue }
                        let x = min(max(CGFloat(fraction) * size.width - 1, 0), size.width - 2)
                        path.addRect(CGRect(x: x, y: size.height * 0.25, width: 2, height: size.height * 0.5))
                    }
                    context.fill(path, with: .color(category.style.tint))
                }
            }
            .frame(height: 28)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    if index > 0 { Spacer(minLength: 4) }
                    Text(label)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(events.count) events over the range")
    }

    /// Start, three evenly spaced marks, then "now".
    private var labels: [String] {
        (0..<4).map { step in
            let time = now.addingTimeInterval(-range + range * Double(step) / 4)
            return range > 86_400
                ? time.formatted(.dateTime.weekday(.abbreviated).day())
                : time.formatted(date: .omitted, time: .shortened)
        } + ["now"]
    }
}

private struct DayHeading: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Time (or span) · severity · title and detail · category · how it ended.
private struct TimelineRowView: View {
    let row: TimelineRow
    /// The day heading the row sits under: that of its latest activity.
    let day: Date
    let shaded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            time.frame(width: 64, alignment: .leading)
            SeverityMark(level: row.peakSeverity, font: .caption2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title.lineLimit(1)
                    if row.count > 1 { CountChip(text: "×\(row.count)") }
                }
                if let detail = row.event.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CategoryTag(category: row.event.category).frame(width: 110, alignment: .leading)
            status.frame(width: 120, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shaded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(TimelinePhrase.timeLines(row, day: day).enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var title: Text {
        let name = Text(row.event.title).fontWeight(.medium)
        guard let end = row.end else { return name }
        // Stored titles already carry an arrow ("Memory pressure → Warning"), so the recovery
        // joins with a separator rather than a second arrow.
        return Text("\(name) \(Text("· \(TimelinePhrase.recovery(end))").foregroundStyle(.secondary))")
    }

    @ViewBuilder
    private var status: some View {
        switch TimelinePhrase.status(row) {
        case .lasted(let duration):
            Text("Lasted \(Format.lasted(duration))")
                .foregroundStyle(HealthLevel.healthy.tint.readableInk(on: .card, minimum: 4.5))
                .monospacedDigit()
        case .ongoing:
            Text("Ongoing")
                .fontWeight(.medium)
                .foregroundStyle(row.peakSeverity.tint.readableInk(on: .card, minimum: 4.5))
        case .endNotRecorded:
            Text("End not recorded")
                .foregroundStyle(.secondary)
                .help("Mac Pulse restarted before this ended, so when it ended is not known")
        case .none:
            EmptyView()
        }
    }
}

/// The row's wording, kept out of the view so it can be tested.
enum TimelinePhrase {
    enum Status: Equatable {
        case lasted(TimeInterval), ongoing, endNotRecorded, none
    }

    static func status(_ row: TimelineRow) -> Status {
        if let duration = row.duration { return .lasted(duration) }
        if row.endUnknown { return .endNotRecorded }
        return row.isOngoing ? .ongoing : .none
    }

    /// How the Episode ended, from the event that ended it: an alert resolves, the connection comes
    /// back online, anything else returns to normal.
    static func recovery(_ end: TimelineEvent) -> String {
        let at = clock(end.time)
        switch end.category {
        case .alert: return "resolved at \(at)"
        case .connectivity: return "back online at \(at)"
        default: return "back to normal at \(at)"
        }
    }

    /// The time column. Rows sit under the day of their latest activity, so a start on an earlier
    /// day carries its date ("29 Sep" over "23:50"); a repeated row shows its first–last span.
    static func timeLines(_ row: TimelineRow, day: Date, calendar: Calendar = .current) -> [String] {
        let start = row.count > 1 || row.isEpisode ? row.firstTime : row.event.time
        var lines: [String] = []
        if calendar.startOfDay(for: start) != day {
            lines.append(start.formatted(.dateTime.day().month(.abbreviated)))
        }
        if row.count > 1 {
            lines += ["\(clock(start))–", clock(row.lastTime)]
        } else {
            lines.append(clock(start))
        }
        return lines
    }

    private static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

/// A category as a tinted dot and its name.
private struct CategoryTag: View {
    let category: TimelineCategory

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(category.style.tint).frame(width: 6, height: 6)
            Text(category.displayName)
                .font(.caption)
                .foregroundStyle(category.style.tint.readableInk(on: .card, minimum: 4.5))
                .lineLimit(1)
        }
    }
}
