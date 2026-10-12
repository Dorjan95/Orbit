import SwiftUI
import AppKit

/// Outside the section's scroll area, visible throughout the main window.
struct AgentUsageFooter: View {
    @Bindable var coordinator: Coordinator
    var body: some View {
        HStack(spacing: 14) {
            AgentUsageIndicator(name: "Codex", snapshot: coordinator.usage.codex, error: coordinator.usage.codexError, refreshing: coordinator.usage.refreshing)
            Rectangle().fill(OrbitDesign.line).frame(width: 1, height: 34)
            AgentUsageIndicator(name: "Claude", snapshot: coordinator.usage.claude, error: coordinator.usage.claudeError, refreshing: coordinator.usage.refreshing, needsQuotaPermission: coordinator.usage.claudeNeedsQuotaPermission, executable: coordinator.claudePath)
            Button {
                Task { await coordinator.usage.refresh(codexPath: coordinator.codexPath, claudePath: coordinator.claudePath) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 26, height: 30)
            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(coordinator.usage.refreshing)
                .accessibilityLabel("Aggiorna utilizzo Codex e Claude").help("Aggiorna le quote dell’account senza inviare richieste ai modelli")
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(OrbitDesign.carbon)
        .overlay(alignment: .top) { Rectangle().fill(OrbitDesign.line).frame(height: 1) }
        .task {
            guard coordinator.usage.enabled else { return }
            while !Task.isCancelled {
                await coordinator.usage.refresh(codexPath: coordinator.codexPath, claudePath: coordinator.claudePath)
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
}

private struct AgentUsageIndicator: View {
    let name: String
    let snapshot: AgentUsageSnapshot?
    let error: String?
    let refreshing: Bool
    var needsQuotaPermission = false
    var executable: String? = nil
    @State private var expanded = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let current = snapshot?.isCurrent(at: context.date) == true && snapshot?.windows.isEmpty == false && error == nil
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Circle().fill(current ? (snapshot?.windows.contains { $0.remainingPercent <= 10 } == true ? Color.orange : OrbitDesign.lime) : OrbitDesign.tertiaryText).frame(width: 5, height: 5)
                        Text(name).font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    if current, let windows = snapshot?.windows, !windows.isEmpty {
                        Text(windows.prefix(2).map { "\($0.label): \(Int($0.remainingPercent.rounded()))% rimasto" }.joined(separator: " · "))
                            .font(.system(size: 10, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.85)
                    } else {
                        Text(error ?? snapshot?.message ?? (refreshing ? "Aggiornamento…" : snapshot == nil ? "Quote non rilevate" : "Dati da aggiornare"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if current, let reset = snapshot?.windows.compactMap(\.resetsAt).min() {
                        Text("Ripristino " + reset.formatted(.relative(presentation: .named)))
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, minHeight: 39, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Utilizzo e limiti dell’account " + name)
                .popover(isPresented: $expanded, arrowEdge: .top) { details(current: current) }
        }
    }
    private func details(current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name + " · utilizzo account").font(.headline)
            if !current { Text(error ?? snapshot?.message ?? "Aggiorna per rilevare le quote correnti.").font(.caption).foregroundStyle(.secondary) }
            if needsQuotaPermission {
                Text("Il login Claude attuale permette di usare il modello, ma manca il permesso per leggere le quote. Esegui un nuovo login da Terminale e poi aggiorna. Orbit non cambia il tuo accesso automaticamente.").font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("claude auth login").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Button("Copia comando di accesso") {
                    let path = executable ?? "claude"
                    let command = "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "' auth login"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                }.controlSize(.small)
            }
            if let snapshot {
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(window.label); Spacer(); Text("\(window.usedPercent, specifier: "%.0f")% usato · \(window.remainingPercent, specifier: "%.0f")% rimasto") }
                        ProgressView(value: min(100, window.usedPercent), total: 100).tint(window.remainingPercent <= 10 ? .orange : OrbitDesign.lime)
                        if let date = window.resetsAt { Text("Ripristino: " + date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                    }.font(.system(size: 11))
                }
                Text((current ? "Aggiornato " : "Ultimo rilevamento ") + snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text("Le quote sono condivise con gli altri utilizzi dell’account. Aggiornamento ogni 5 minuti mentre la finestra è aperta. Le percentuali mancanti non vengono stimate.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 330)
    }
}
