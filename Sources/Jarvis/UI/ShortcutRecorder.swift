import SwiftUI
import AppKit
import Carbon.HIToolbox

/// "Record shortcut" field: click, press a chord, it validates via Carbon before saving (§3.6).
struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording.toggle()
                if recording { beginRecording() } else { endRecording() }
            } label: {
                Group {
                    if recording { Text("Premi la combinazione…").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor) }
                    else { KeyCaps(hotkey: hotkey, size: 12) }
                }
                .frame(minWidth: 120, minHeight: 22)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(recording ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .buttonStyle(PressableStyle())
            .help(recording ? "Esc per annullare" : "Fai clic e premi la nuova combinazione")
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording() {
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = Hotkey.carbonModifiers(e.modifierFlags)
            if e.keyCode == 53 { endRecording(); return nil } // esc cancels
            guard mods != 0 else { message = "Aggiungi almeno un modificatore (⌘ ⇧ ⌥ ⌃)"; return nil }
            let hk = Hotkey(keyCode: UInt32(e.keyCode), modifiers: mods)
            if HotkeyMonitor.shared.canRegister(hk) { hotkey = hk; message = nil }
            else { message = "\(hk.display) è già usata da un'altra app" }
            endRecording()
            return nil
        }
    }

    private func endRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
