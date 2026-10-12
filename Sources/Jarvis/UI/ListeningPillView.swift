import SwiftUI

enum PillState: Equatable { case listening, thinking, speaking, clarify, error }

@MainActor @Observable
final class PillModel {
    var automaticCapture = false
    var state: PillState = .listening
    var transcript = ""
    var secondary = ""       // clarify question / error text
    var level: Float = 0
    var fallbackBadge = false
    var visible = false
}

/// §5.1 — 360 pt pill at the top of the screen. A state label, the transcript (max 3 lines, newest words kept
/// visible) and, while listening, a live level meter plus the two things you can do next.
struct ListeningPillView: View {
    @Bindable var model: PillModel
    var projectName: String = ""
    var runningCount: Int = 0
    var backendLabel: String = "Codex"
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if model.visible { content } else { compact }
        }
        .frame(width: 380)
        .background(OrbitDesign.carbon)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(OrbitDesign.line, lineWidth: 1))
        .foregroundStyle(OrbitDesign.chalk).tint(OrbitDesign.lime).preferredColorScheme(.dark)
    }

    private var compact: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 17, weight: .medium)).foregroundStyle(OrbitDesign.lime)
                Text(projectName.isEmpty ? "ORBIT" : projectName)
                    .font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(projectName.isEmpty ? 1 : 0)
                    .lineLimit(1)
                Spacer(minLength: 5)
                Text(runningCount > 0 ? "\(runningCount) IN CORSO" : backendLabel.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(runningCount > 0 ? OrbitDesign.lime : OrbitDesign.secondaryText)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(OrbitDesign.secondaryText)
            }
            .padding(.horizontal, 18).frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(PressableStyle()).help("Mostra o nascondi le sessioni")
            .accessibilityLabel("Orbit, \(runningCount) sessioni in corso. Mostra o nascondi le sessioni.")
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 14) {
            orb
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stateLabel.uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(tint)
                    if model.fallbackBadge {
                        Label("voce di sistema", systemImage: "speaker.wave.1")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .help("Fish Audio non è configurato: sto usando la voce di macOS")
                    }
                }
                Text(primaryText)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(1)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .foregroundStyle(model.transcript.isEmpty && model.state == .listening ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if !model.secondary.isEmpty {
                    Text(model.secondary)
                        .font(.system(size: 12))
                        .foregroundStyle(model.state == .error ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 12)
        .frame(width: 380, alignment: .leading)
        .frame(minHeight: 64)
        .animation(Motion.spring, value: model.state)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch model.state {
        case .listening, .thinking, .speaking: OrbitDesign.lime
        case .clarify: OrbitDesign.warning
        case .error: OrbitDesign.error
        }
    }

    private var stateLabel: String {
        switch model.state {
        case .listening: "Ti ascolto"
        case .thinking: "Ci penso"
        case .speaking: "Rispondo"
        case .clarify: "Una domanda"
        case .error: "Qualcosa non va"
        }
    }

    private var primaryText: String {
        switch model.state {
        case .listening: model.transcript.isEmpty ? "Parla pure…" : model.transcript
        case .thinking: model.transcript.isEmpty ? "Un attimo…" : model.transcript
        case .speaking, .clarify, .error: model.transcript
        }
    }

    private var hint: String? {
        switch model.state {
        case .listening: model.automaticCapture ? "Fai una pausa per inviare · Esc per annullare" : "Rilascia per inviare · Esc per annullare"
        case .clarify: "Tieni premuta la scorciatoia per rispondere"
        default: nil
        }
    }

    /// 36 pt tinted disc that carries the live visual for each state.
    private var orb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(OrbitDesign.surface)
            switch model.state {
            case .listening: LevelMeter(level: model.level)
            case .thinking: ThinkingDots()
            case .speaking: MiniWaveform()
            case .clarify:
                Image(systemName: "questionmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            case .error:
                Image(systemName: "exclamationmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            }
        }
        .frame(width: 36, height: 36)
        .animation(Motion.spring, value: model.state)
    }
}

/// Five bars driven by the real mic level, centre bars tallest, so speaking visibly moves them.
struct LevelMeter: View {
    let level: Float
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.45]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(OrbitDesign.lime)
                    .frame(width: 3, height: 4 + 14 * min(1, CGFloat(level) * weights[i] * 1.5))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

struct ThinkingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3) { i in
                Circle().fill(OrbitDesign.lime).frame(width: 4.5, height: 4.5)
                    .opacity(on ? 1 : 0.3)
                    .animation(Motion.reduce ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
    }
}

struct MiniWaveform: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4) { i in
                Capsule().fill(OrbitDesign.lime).frame(width: 3, height: on ? 14 : 5)
                    .animation(Motion.reduce ? nil : .easeInOut(duration: 0.3 + Double(i) * 0.07).repeatForever(autoreverses: true), value: on)
            }
        }
        .frame(height: 16)
        .onAppear { on = true }
    }
}
