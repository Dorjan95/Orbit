import XCTest
import SwiftUI
import AppKit
@testable import Jarvis

/// Opt-in documentation export. Uses only fictional data in XCTest's isolated store.
final class DocumentationSnapshotTests: XCTestCase {
    @MainActor
    func testExportDocumentationImages() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_DOCS_OUTPUT"] else {
            throw XCTSkip("Set ORBIT_DOCS_OUTPUT to export documentation screenshots")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let coordinator = Coordinator(enableServices: false)
        coordinator.settings.settings = Settings()
        coordinator.usage.codex = .init(windows: [.init(label: "5h", usedPercent: 35, resetsAt: .now.addingTimeInterval(7200)), .init(label: "7g", usedPercent: 18, resetsAt: .now.addingTimeInterval(200000))])
        coordinator.usage.claude = .init(windows: [.init(label: "5h", usedPercent: 12, resetsAt: .now.addingTimeInterval(10800)), .init(label: "7g", usedPercent: 24, resetsAt: .now.addingTimeInterval(300000))])
        coordinator.registry.projects = [
            Project(name: "Website", path: "~/Projects/website", aliases: ["il sito"]),
            Project(name: "Mobile App", path: "~/Projects/mobile-app", aliases: ["l’app"]),
            Project(name: "API Server", path: "~/Projects/api-server", aliases: ["il backend"])
        ]
        for session in coordinator.sessions.sessions { coordinator.sessions.dismiss(session.id) }
        for session in [
            Session(id: "docs_01", projectName: "Website", projectPath: "~/Projects/website", agent: .codex,
                    task: "Aggiungi una pagina prezzi chiara e responsive.", status: .running,
                    activity: "Aggiorna i componenti della pagina prezzi", startedAt: Date().addingTimeInterval(-180)),
            Session(id: "docs_02", projectName: "API Server", projectPath: "~/Projects/api-server", agent: .codex,
                    task: "Verifica gli endpoint e aggiungi i test mancanti.", status: .needsInput,
                    activity: "Quale ambiente devo usare per i test?", startedAt: Date().addingTimeInterval(-120))
        ] { coordinator.sessions.insert(session) }
        for section in [SettingsSection.general, .sessions, .projects, .workflows] {
            let view = NSHostingView(rootView: SettingsView(coordinator: coordinator, section: section))
            view.frame = NSRect(x: 0, y: 0, width: 820, height: 680)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("orbit-\(section.rawValue).png"))
            window.contentView = nil
        }
    }
}
