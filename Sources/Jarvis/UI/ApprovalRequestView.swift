import SwiftUI

/// The operation stays visible beside its choices; no default grant or Return shortcut.
struct ApprovalRequestView: View {
    let approval: AgentApproval
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Permesso richiesto", systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            Text(approval.title).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
            ScrollView {
                Text(approval.details).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            Text(approval.options.contains { $0.kind == "allow_turn" } ? "L'accesso concesso termina con il turno corrente." : "La scelta vale solo per questa richiesta.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            // Reject first in the keyboard focus order. Option IDs remain opaque.
            ForEach(approval.options.sorted { $0.kind == "reject_once" && $1.kind != "reject_once" }) { option in
                Button { onSelect(option.optionID) } label: {
                    Label(option.label, systemImage: option.kind.hasPrefix("allow_") ? "checkmark" : "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(approval.state != .pending)
                .accessibilityLabel(option.label + ": " + approval.title)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
