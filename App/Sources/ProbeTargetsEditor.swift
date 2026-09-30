import SwiftUI
import PulseCore

/// Settings → Network: the internet targets, in order. Row 0 is the Primary Target, the one that
/// drives the Internet Health Level; the rest are comparisons on the Network page's Path card.
struct ProbeTargetsEditor: View {
    @Binding var targets: [ProbeTarget]
    var maxCount = ProbeTargets.maxCount
    var defaults = ProbeTargets.defaults

    var body: some View {
        Section {
            ForEach(targets.indices, id: \.self) { index in
                row(index)
            }
            .onMove { targets.move(fromOffsets: $0, toOffset: $1) }
            HStack(spacing: 8) {
                Button { targets.append(ProbeTarget("")) } label: { Image(systemName: "plus") }
                    .disabled(targets.count >= maxCount)
                    .help("Add a target")
                Button { if targets.count > 1 { targets.removeLast() } } label: { Image(systemName: "minus") }
                    .disabled(targets.count <= 1)
                    .help("Remove the last target")
                Spacer()
                Button("Restore defaults") { targets = defaults }
                    .disabled(targets == defaults)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Internet targets")
        } footer: {
            Text("The first target is Primary and sets the internet Health Level. Drag to reorder. Each target adds ~120 KB/h of probes; \(maxCount) keeps Mac Pulse under 1 MB/h.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Address", text: address(index), prompt: Text("1.1.1.1 or host name"))
                    .labelsHidden()
                TextField("Label", text: label(index), prompt: Text("Label (optional)"))
                    .labelsHidden()
                    .frame(width: 130)
                // Drawn on every row and shown on the first, so the label fields line up.
                Text("Primary")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
                    .opacity(index == 0 ? 1 : 0)
                    .accessibilityHidden(index != 0)
            }
            if let problem = problem(index) {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Why this row is not probed; nil when it is.
    private func problem(_ index: Int) -> String? {
        guard targets.indices.contains(index) else { return nil }
        let address = Self.normalized(targets[index].address)
        if address.isEmpty { return "Enter an address. This row is not probed." }
        if ProbeTarget.kind(of: address) == nil { return "Not an IPv4 or IPv6 address or host name. This row is not probed." }
        if targets[..<index].contains(where: { Self.normalized($0.address) == address }) {
            return "Already in the list. This row is not probed."
        }
        return nil
    }

    static func normalized(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Index bindings that tolerate a row removed while its field still holds focus.
    private func address(_ index: Int) -> Binding<String> {
        Binding(get: { targets.indices.contains(index) ? targets[index].address : "" },
                set: { if targets.indices.contains(index) { targets[index].address = $0 } })
    }

    private func label(_ index: Int) -> Binding<String> {
        Binding(get: { targets.indices.contains(index) ? targets[index].label ?? "" : "" },
                set: { if targets.indices.contains(index) { targets[index].label = $0.isEmpty ? nil : $0 } })
    }
}
