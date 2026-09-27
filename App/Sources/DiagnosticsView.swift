import SwiftUI
import PulseCore
import PulseEngine

/// PRD §10 results: every finding separates Observed fact / Possible cause / Recommendation.
struct DiagnosticsView: View {
    let metrics: LiveMetrics
    @Environment(\.dismiss) private var dismiss
    @State private var report: DiagnosticReport?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostics").font(.title2.weight(.semibold))
                Spacer()
                if report != nil {
                    Button("Run Again") { Task { await run() } }
                        .disabled(isRunning)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Group {
                if let report {
                    // A re-run keeps the findings on screen: replacing a readable report with a
                    // spinner throws away what the user was in the middle of reading.
                    results(report).overlay(alignment: .top) {
                        if isRunning { rerunBanner }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Checking the last 15 minutes and probing the network…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 620, height: 520)
        .task { await run() }
    }

    /// Keeps the current report visible while the next one is gathered; only the first run has
    /// nothing to show.
    private func run() async {
        isRunning = true
        defer { isRunning = false }
        report = await metrics.runDiagnostics()
    }

    private var rerunBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking again…").font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.background, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .padding(.top, 8)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func results(_ report: DiagnosticReport) -> some View {
        if report.findings.isEmpty {
            ContentUnavailableView("No problems detected", systemImage: "checkmark.circle",
                                   description: Text("Nothing unusual in the last 15 minutes, and the network responds normally."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Covers \(report.from.formatted(date: .omitted, time: .shortened))–\(report.to.formatted(date: .omitted, time: .shortened)). Causes are suggestions, not certainties.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.findings) { FindingCard(finding: $0) }
                }
                .padding(16)
            }
        }
    }
}

private struct FindingCard: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(finding.title).font(.headline)
                Spacer()
                HealthBadge(level: finding.health)
            }
            section("Observed") {
                ForEach(finding.observed, id: \.self) { Text($0).monospacedDigit() }
            }
            section("Possible cause") { Text(finding.possibleCause.text) }
            section("Recommendation") { Text(finding.recommendation) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The card read as one finding: state, what was observed, what might explain it, what to do.
    private var spoken: String {
        ([finding.title, Format.health(finding.health)]
         + finding.observed
         + ["Possible cause: \(finding.possibleCause.text)",
            "Recommendation: \(finding.recommendation)"])
            .joined(separator: ". ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Sentence case, like every other label in the app.
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
