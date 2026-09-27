import SwiftUI
import PulseCore
import PulseEngine

/// PRD §10 results: every finding separates Observed fact / Possible cause / Recommendation.
struct DiagnosticsView: View {
    let metrics: LiveMetrics
    @Environment(\.dismiss) private var dismiss
    @State private var report: DiagnosticReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostics").font(.title2.weight(.semibold))
                Spacer()
                if report != nil {
                    Button("Run Again") { Task { await run() } }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Group {
                if let report {
                    results(report)
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

    private func run() async {
        report = nil
        report = await metrics.runDiagnostics()
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
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
