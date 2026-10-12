import AppKit

/// Folder chooser that actually shows up from a menu-bar (accessory) app.
/// A bare `NSOpenPanel.runModal()` from an app that isn't frontmost can end without ever putting the panel on screen,
/// so the panel is attached as a sheet to the window it came from, after bringing the app forward.
@MainActor
enum FolderPicker {
    static func choose(message: String = "Scegli la cartella del progetto", _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Scegli"
        NSApp.activate(ignoringOtherApps: true)
        let host = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }
        AppLog.write("folder picker: open (sheet=\(host != nil))")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            AppLog.write("folder picker: \(response == .OK ? "chosen \(panel.url?.path ?? "-")" : "cancelled")")
            if response == .OK, let url = panel.url { done(url) }
        }
        if let host {
            host.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
