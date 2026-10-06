import OrbitCore
import SwiftUI

struct MascotSettingsView: View {
  @Bindable var controller: OrbitController
  @State private var preview: MascotState = .greeting
  @State private var clip = "Big_Wave_Hello"
  @State private var epoch = Date()
  @State private var playhead = 0.0
  @State private var playing = true
  private let clock = Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()
  var duration: Double { MotionLibrary.shared?.clips[clip]?.duration ?? 1 }
  var body: some View {
    VStack(spacing: 20) {
      Card("Aero, la mascotte di Orbit") {
        ControlRow("Mostra la mascotte sul desktop") {
          Toggle("Mascotte", isOn: controller.binding(\.mascotVisible))
        }
        ControlRow("Anima i gesti") {
          Toggle("Animazioni", isOn: controller.binding(\.mascotMotion))
        }
        ControlRow("Mostra il messaggio di stato") {
          Toggle("Messaggio", isOn: controller.binding(\.mascotCaption))
        }
        ControlRow("Dimensione") {
          Slider(value: controller.binding(\.mascotHeight), in: 120...320).frame(width: 220)
          Text("\(Int(controller.settings.mascotHeight))").monospacedDigit().font(.system(size: 11))
        }
        HStack {
          Text("Trascina Aero in qualunque punto dello schermo. Cliccala per parlare.").font(
            .system(size: 12)
          ).foregroundStyle(Palette.muted)
          Spacer()
          Button("Ripristina posizione") { controller.settings.mascotPosition = nil }
        }
      }
      Card("Gesti e animazioni native") {
        HStack(alignment: .top, spacing: 25) {
          VStack(spacing: 0) {
            ZStack {
              if let symbol = preview.symbol {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(
                  preview == .problem ? .orange : Palette.accent)
              }
            }.frame(height: 38)
            AeroView(
              state: preview, epoch: epoch, settings: controller.settings, previewClip: clip,
              scrub: playhead
            ).frame(width: 250, height: 290)
            Text(preview.message).font(.system(size: 12, weight: .semibold)).foregroundStyle(
              Palette.muted)
          }
          VStack(alignment: .leading, spacing: 15) {
            Text("Situazione").font(.system(size: 12)).foregroundStyle(Palette.muted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
              ForEach(MascotState.allCases, id: \.self) { state in
                Button(state.title) {
                  preview = state
                  clip =
                    MotionLibrary.shared?.clip(for: state, settings: controller.settings)
                    ?? "Wave_One_Hand"
                  replay()
                }.buttonStyle(.bordered).tint(preview == state ? Palette.accent : .gray).frame(
                  maxWidth: .infinity)
              }
            }
            Picker("Animazione", selection: $clip) {
              ForEach(MotionLibrary.shared?.clips.keys.sorted() ?? [], id: \.self) { name in
                Text(name.replacingOccurrences(of: "_", with: " ")).tag(name)
              }
            }.labelsHidden()
            Button("Usa per \(preview.title.lowercased())") {
              controller.settings.clips[preview.rawValue] = clip
            }.buttonStyle(.borderedProminent)
            Button("Ripristina questo gesto") {
              controller.settings.clips[preview.rawValue] = nil
              clip =
                MotionLibrary.shared?.clip(for: preview, settings: controller.settings)
                ?? "Wave_One_Hand"
              replay()
            }
            Text(
              "I gesti si eseguono una volta e mantengono la posa finale. Solo il lavoro usa un ciclo. Con Riduci movimento, Aero resta in posa."
            ).font(.system(size: 11)).foregroundStyle(Palette.muted)
          }.frame(maxWidth: .infinity)
        }
        HStack {
          Button {
            if playing {
              playing = false
            } else {
              if playhead >= duration { playhead = 0 }
              epoch = Date().addingTimeInterval(-playhead)
              playing = true
            }
          } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
          }
          Slider(
            value: $playhead, in: 0...max(0.01, duration),
            onEditingChanged: { editing in if editing { playing = false } })
          Text(
            "\(playhead.formatted(.number.precision(.fractionLength(1)))) / \(duration.formatted(.number.precision(.fractionLength(1)))) s"
          ).font(.system(size: 10, design: .monospaced))
          Button("Ripeti", action: replay)
        }
      }
    }.toggleStyle(.switch).onChange(of: clip) { _, _ in replay() }.onReceive(clock) { now in
      if playing {
        playhead = min(duration, max(0, now.timeIntervalSince(epoch)))
        if playhead >= duration { playing = false }
      }
    }
  }
  func replay() {
    epoch = Date()
    playhead = 0
    playing = true
  }
}
