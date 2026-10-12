import AppKit
import SwiftUI

@MainActor final class Orbit3DPreviewWindow: NSObject, NSWindowDelegate {
    static let shared = Orbit3DPreviewWindow()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Orbit — Anteprima 3D"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: Orbit3DPreview())
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Release the viewport and its GPU scene when the study closes.
        window?.contentView = nil
        window = nil
    }
}

struct Orbit3DPreview: View {
    @State private var started = Date()
    @State private var pausedAt: TimeInterval = 0
    @State private var playing = true
    @State private var clip: OrbitMeshyClip = .bigWave
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duration: TimeInterval { clip.duration }
    private func elapsed(at date: Date) -> TimeInterval {
        reduceMotion ? duration : min(duration,
            pausedAt + (playing ? max(0, date.timeIntervalSince(started)) : 0))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing || reduceMotion)) { context in
            let time = elapsed(at: context.date)
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ORBIT AERO · ANIMAZIONI MESHY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1).foregroundStyle(OrbitDesign.lime)
                        Text("Prova i movimenti").font(.system(size: 27, weight: .heavy, design: .rounded))
                    }
                    Spacer()
                    Picker("Animazione", selection: $clip) {
                        ForEach(OrbitMeshyClip.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.frame(width: 300)
                }
                HStack(spacing: 26) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22).fill(OrbitDesign.raisedSurface)
                        if OrbitMeshyRig.isAvailable {
                            OrbitMeshy3DView(pose: .idle, elapsed: time, moving: !reduceMotion, previewClip: clip)
                                .allowsHitTesting(false)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                        } else {
                            Text("Modello 3D non disponibile").foregroundStyle(OrbitDesign.secondaryText)
                        }
                    }.frame(width: 330, height: 392)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(clip.label).font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(clip.rawValue).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrbitDesign.lime).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Dal tuo modello Meshy, con le pose e i tempi originali.")
                            .font(.system(size: 13)).foregroundStyle(OrbitDesign.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        LabeledContent("Durata", value: String(format: "%.2f s", duration))
                            .font(.system(size: 13))
                        Text(time >= duration ? "Animazione conclusa" : playing ? "In riproduzione" : "In pausa")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(OrbitDesign.lime)
                        Spacer(minLength: 0)
                        Text("Usa il cursore per esaminare le pose. In Impostazioni → Mascotte puoi assegnare questi movimenti agli stati di Orbit.")
                            .font(.system(size: 12)).foregroundStyle(OrbitDesign.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 16)
                }
                HStack(spacing: 12) {
                    Button {
                        pausedAt = 0; started = Date(); playing = true
                    } label: { Label("Riprova", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderedProminent)
                    Button {
                        if playing { pausedAt = elapsed(at: Date()); playing = false }
                        else { started = Date(); playing = true }
                    } label: {
                        Label(time >= duration ? "Conclusa" : playing ? "Pausa" : "Riprendi",
                              systemImage: time >= duration ? "checkmark" : playing ? "pause.fill" : "play.fill")
                    }.buttonStyle(.bordered).disabled(time >= duration || reduceMotion)
                    Slider(value: Binding(get: { time }, set: { pausedAt = $0; playing = false }), in: 0...duration)
                        .accessibilityLabel("Posizione dell’animazione Meshy").disabled(reduceMotion)
                    Text(String(format: "%.1f s", time)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OrbitDesign.secondaryText).frame(width: 42)
                }
            }.padding(30).frame(width: 760, height: 600)
                .background(OrbitDesign.screen).foregroundStyle(OrbitDesign.chalk)
                .tint(OrbitDesign.lime).preferredColorScheme(.dark)
                .onChange(of: time) {
                    if time >= duration && playing { pausedAt = duration; playing = false }
                }
                .onChange(of: clip) { pausedAt = 0; started = Date(); playing = true }
        }
    }
}
