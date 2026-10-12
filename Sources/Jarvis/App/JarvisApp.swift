import AppKit
import SwiftUI

@main
struct OrbitMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, no Dock (§1)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var coordinator: Coordinator!
    private var launched = false
    private var pendingURLs: [URL] = []
    private var statusItem: NSStatusItem!
    private var pillPanel: FloatingPanel<ListeningPillView>!
    private var overlayPanel: FloatingPanel<SessionsOverlayView>!
    private var mascotPanel: FloatingPanel<OrbitMascotView>!
    private var positioningPanels = false
    private var draggingMascot = false
    private let mascotAnimation = OrbitAnimationModel()
    private var knownSessionStatuses: [String: SessionStatus] = [:]
    private var draggingOverlay = false
    private var settingsWindow: NSWindow?
    /// Keep the overlay preference while the main window temporarily replaces it.
    private var settingsPresented = false
    private var onboardingWindow: NSWindow?
    private var observation: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Self.acquireSingleInstanceLock() else {
            // Another Orbit is already running — bail out before touching any JSON store.
            NSApp.terminate(nil); return
        }
        coordinator = Coordinator()
    }

    nonisolated(unsafe) private static var lockFD: Int32 = -1
    /// flock on a pidfile: a second instance fails to lock and exits, so it can never overwrite the stores.
    private static func acquireSingleInstanceLock() -> Bool {
        let path = AppPaths.root.appendingPathComponent("jarvis.lock").path
        lockFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return true }
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupTray()
        setupPanels()
        coordinator.onPillChanged = { [weak self] in self?.refreshPill(); self?.refreshMascot() }
        coordinator.onLevelChanged = { [weak self] in guard let self else { return }; self.pillPanel.update(self.pillView()) }
        coordinator.onOverlayToggle = { [weak self] in self?.toggleOverlay() }
        knownSessionStatuses = Dictionary(uniqueKeysWithValues: coordinator.sessions.sessions.map { ($0.id, $0.status) })
        startObserving()
        installSignalHandlers()
        if !coordinator.settings.settings.onboardingComplete { showOnboarding() }
        else if SpeechService.micStatus == .notDetermined || SpeechService.speechStatus == .notDetermined {
            // Ad-hoc rebuilds can reset TCC grants. Ask again rather than leaving
            // an already-configured voice assistant silently unable to listen.
            Task { @MainActor [weak self] in
                let result = await SpeechService.requestPermissions()
                AppLog.write("updated app permissions: mic=\(result.mic) speech=\(result.speech)")
                self?.coordinator.refreshWake()
            }
        }
        if coordinator.settings.settings.overlayVisible { showOverlay() }
        launched = true
        let queued = pendingURLs; pendingURLs = []
        if !queued.isEmpty { application(NSApp, open: queued) }
    }

    private var sigSources: [DispatchSourceSignal] = []
    /// SIGTERM/SIGHUP (logout, `kill`) must still take the agent trees down — no orphans (§10.7).
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.coordinator.prepareForQuit(); exit(0) }
            src.resume()
            sigSources.append(src)
        }
    }

    /// Accessory apps get no main menu, so ⌘C/⌘V/⌘A would be dead in text fields without this.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Esci da Orbit", action: #selector(quit), keyEquivalent: "q").target = self
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Modifica"); editItem.submenu = edit
        edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    // MARK: Tray (§5.3)

    private func setupTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateTrayIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Mostra o nascondi le sessioni", action: #selector(toggleOverlayAction), keyEquivalent: "")
        menu.addItem(withTitle: "Pannello delle sessioni…", action: #selector(showSessions), keyEquivalent: "")
        handsFreeItem = menu.addItem(withTitle: "Ascolta quando dici «Hey Orbit» o batti le mani", action: #selector(toggleHandsFree), keyEquivalent: "")
        handsFreeItem?.state = coordinator.settings.settings.handsFree ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Progetti…", action: #selector(showProjects), keyEquivalent: "")
        menu.addItem(withTitle: "Impostazioni…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Rifai la configurazione iniziale", action: #selector(showOnboardingAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Informazioni su Orbit", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Esci da Orbit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private var handsFreeItem: NSMenuItem?

    @objc private func toggleHandsFree() {
        coordinator.settings.settings.handsFree.toggle()
        handsFreeItem?.state = coordinator.settings.settings.handsFree ? .on : .off
        coordinator.refreshWake()
    }

    private func updateTrayIcon() {
        guard let button = statusItem.button else { return }
        let running = !coordinator.sessions.running.isEmpty
        let img = NSImage(systemSymbolName: running ? "waveform.badge.magnifyingglass" : "waveform", accessibilityDescription: "Orbit")
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.image = img?.withSymbolConfiguration(cfg)
        button.image?.isTemplate = true
        if running {
            // Small accent badge dot drawn over the template glyph.
            let base = button.image!
            let badged = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
                return true
            }
            badged.isTemplate = false
            button.image = badged
        }
    }

    /// Event-driven UI refresh via Observation; no timers.
    private func startObserving() {
        observation = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.coordinator.sessions.sessions
                        _ = self.coordinator.settings.settings.overlayOpacity
                        _ = self.coordinator.settings.settings.pushToTalk
                        _ = self.coordinator.settings.settings.handsFree
                        _ = self.coordinator.settings.settings.showIdlePill
                        _ = self.coordinator.settings.settings.mascotEnabled
                        _ = self.coordinator.settings.settings.mascotSize
                        _ = self.coordinator.settings.settings.mascotOrigin
                        _ = self.coordinator.settings.settings.mascotAnimations
                        _ = self.coordinator.settings.settings.mascotShowStatus
                        _ = self.coordinator.settings.settings.codexAssistantSelection.provider
                        _ = self.coordinator.settings.settings.orchestratorAgent
                    } onChange: { c.resume() }
                }
                self.updateTrayIcon()
                self.handsFreeItem?.state = self.coordinator.settings.settings.handsFree ? .on : .off
                self.refreshPill()
                self.refreshOverlay()
                for session in self.coordinator.sessions.sessions {
                    if !session.pendingApprovals.isEmpty, self.knownSessionStatuses[session.id] != .needsInput,
                       !self.overlayPanel.isVisible { self.showOverlay() }
                    if let old = self.knownSessionStatuses[session.id], old.isOngoing, old != session.status {
                        if session.status == .done { self.mascotAnimation.react(.success, duration: self.coordinator.settings.settings.mascotReactionDuration(for: .success)) }
                        else if session.status == .failed { self.mascotAnimation.react(.error, duration: self.coordinator.settings.settings.mascotReactionDuration(for: .error)) }
                    }
                }
                self.knownSessionStatuses = Dictionary(uniqueKeysWithValues: self.coordinator.sessions.sessions.map { ($0.id, $0.status) })
                self.refreshMascot()
                // A session Orbit just started: show the panel top-right so it is visible without ⇧⌘O.
                let running = Set(self.coordinator.sessions.running.map(\.id))
                if !running.subtracting(self.knownRunning).isEmpty, !self.overlayPanel.isVisible { self.showOverlay() }
                self.knownRunning = running
            }
        }
    }
    private var knownRunning: Set<String> = []

    // MARK: Panels

    private func setupPanels() {
        pillPanel = FloatingPanel(content: pillView(), draggable: false)
        pillPanel.alphaValue = 0
        overlayPanel = FloatingPanel(content: overlayView(), draggable: true)
        overlayPanel.delegate = self
        overlayPanel.alphaValue = 0
        mascotPanel = FloatingPanel(content: mascotView(), draggable: true)
        mascotPanel.delegate = self
        refreshPill()
        refreshOverlay()
        refreshMascot()
        NotificationCenter.default.addObserver(self, selector: #selector(screenLayoutChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private var primaryScreen: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func pillView() -> ListeningPillView {
        let settings = coordinator.settings.settings
        return ListeningPillView(model: coordinator.pill,
            projectName: coordinator.sessions.running.first?.projectName ?? "",
            runningCount: coordinator.sessions.running.count,
            backendLabel: settings.orchestratorAgent == .codex ? settings.assistantBackend.label : "Claude",
            onToggle: { [weak self] in self?.toggleOverlay() })
    }

    @objc private func screenLayoutChanged() { refreshPill(); refreshOverlay(); refreshMascot() }

    private func overlayView() -> SessionsOverlayView {
        SessionsOverlayView(store: coordinator.sessions, chord: coordinator.settings.settings.pushToTalk,
                            maximumHeight: max(160, min(560, (overlayPanel?.screen ?? primaryScreen)?.visibleFrame.height ?? 900) - 48),
                            onClose: { [weak self] in self?.hideOverlay() },
                            onOpen: { [weak self] s in self?.coordinator.open(session: s) },
                            onLog: { [weak self] s in self?.coordinator.showLog(s) },
                            onReply: { [weak self] s, t in self?.coordinator.followUp(session: s, task: t) },
                            onStop: { [weak self] s in self?.coordinator.stop(sessionID: s.id) },
                            onDismiss: { [weak self] s in self?.coordinator.sessions.dismiss(s.id) },
                            onClear: { [weak self] in self?.coordinator.clearHistory() },
                            onResumePending: { [weak self] s in self?.coordinator.resumePending(sessionID: s.id) },
                            onApproval: { [weak self] s, approval, option in self?.coordinator.resolveApproval(sessionID: s.id, approvalID: approval, optionID: option) },
                            onPlanDecision: { [weak self] s, approve in self?.coordinator.decidePlan(sessionID: s.id, approve: approve) },
                            onSteer: { [weak self] s, task in self?.coordinator.steer(sessionID: s.id, task: task) ?? false },
                            onDragState: { [weak self] dragging in
                                guard let self else { return }
                                self.draggingOverlay = dragging
                                if !dragging {
                                    self.coordinator.settings.settings.overlayOrigin = self.overlayPanel.frame.origin
                                    self.refreshOverlay()
                                }
                            })
    }

    private func refreshOverlay() {
        guard !draggingOverlay else { return }
        positioningPanels = true
        defer { positioningPanels = false }
        overlayPanel.update(overlayView())
        overlayPanel.fitToContent(anchorTopCenter: false)
        positionOverlay()
        overlayPanel.alphaValue = overlayPanel.isVisible ? coordinator.settings.settings.overlayOpacity : 0
    }

    private func positionOverlay() {
        guard let screen = primaryScreen else { return }
        let size = overlayPanel.frame.size
        let origin = coordinator.settings.settings.overlayOrigin ?? CGPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.maxY - size.height - 24)
        let frame = DesktopLayout.fittedFrame(origin: origin, size: size,
            screens: NSScreen.screens.map(\.visibleFrame), fallback: screen.visibleFrame)
        overlayPanel.setFrame(frame, display: true)
    }

    private func refreshPill() {
        pillPanel.update(pillView())
        positionPillTopCenter()
        let visible = coordinator.pill.visible || coordinator.settings.settings.showIdlePill
        if visible {
            if !pillPanel.isVisible {
                pillPanel.alphaValue = 0
                pillPanel.orderFrontRegardless()
                animate(pillPanel, alpha: 1, scaleFrom: 1)
            }
        } else {
            pillPanel.orderOut(nil)
        }
    }

    private func positionPillTopCenter() {
        pillPanel.fitToContent(anchorTopCenter: true)
        guard let screen = primaryScreen else { return }
        let frame = DesktopLayout.pillFrame(visible: screen.visibleFrame, size: pillPanel.frame.size)
        pillPanel.setFrame(frame, display: true)
    }

    private func mascotView() -> OrbitMascotView {
        let settings = coordinator.settings.settings
        return OrbitMascotView(model: coordinator.pill, animation: mascotAnimation, runningCount: coordinator.sessions.running.count,
            pendingCount: coordinator.sessions.activeVisible.filter { $0.status == .needsInput }.count,
            size: CGFloat(settings.mascotSize), animations: settings.mascotAnimations,
            showStatus: settings.mascotShowStatus, clipAssignments: settings.mascotClipAssignments,
            onListen: { [weak self] in
                guard let self, self.coordinator.settings.settings.mascotEnabled else { return }
                self.coordinator.toggleMascotListening()
            },
            onOpen: { [weak self] in self?.toggleOverlay() },
            onSettings: { [weak self] in self?.presentSettings(section: .mascot) },
            onHide: { [weak self] in self?.coordinator.settings.settings.mascotEnabled = false },
            onDragState: { [weak self] dragging in
                guard let self else { return }
                self.draggingMascot = dragging
                self.mascotAnimation.dragging = dragging
                if !dragging {
                    self.coordinator.settings.settings.mascotOrigin = self.mascotPanel.frame.origin
                    self.refreshMascot()
                }
            })
    }

    private func refreshMascot() {
        mascotAnimation.syncListening(active: coordinator.pill.visible && coordinator.pill.state == .listening)
        mascotAnimation.syncThinking(active: coordinator.pill.visible && coordinator.pill.state == .thinking)
        guard !draggingMascot, let mascotPanel, let screen = primaryScreen else { return }
        positioningPanels = true
        defer { positioningPanels = false }
        let settings = coordinator.settings.settings
        if settings.mascotEnabled, !mascotAnimation.displayed { mascotAnimation.react(.greeting, duration: settings.mascotReactionDuration(for: .greeting)) }
        mascotAnimation.displayed = settings.mascotEnabled
        mascotPanel.update(mascotView())
        mascotPanel.fitToContent(anchorTopCenter: false)
        let frame = DesktopLayout.fittedFrame(origin: settings.mascotOrigin, size: mascotPanel.frame.size,
            screens: NSScreen.screens.map(\.visibleFrame), fallback: screen.visibleFrame)
        mascotPanel.setFrame(frame, display: true)
        if settings.mascotEnabled { mascotPanel.orderFrontRegardless() }
        else { mascotPanel.orderOut(nil) }
    }

    private func animate(_ panel: NSPanel, alpha: CGFloat, scaleFrom: CGFloat, completion: (@Sendable () -> Void)? = nil) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0.1 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
        if !reduce, let layer = panel.contentView?.layer {
            let anim = CASpringAnimation(keyPath: "transform.scale")
            anim.fromValue = alpha == 1 ? scaleFrom : 1; anim.toValue = alpha == 1 ? 1 : 0.96
            anim.damping = 14; anim.stiffness = 220; anim.duration = 0.35
            layer.add(anim, forKey: "scale")
        }
    }

    private func showOverlay() {
        coordinator.settings.settings.overlayVisible = true
        guard !settingsPresented else {
            overlayPanel.orderOut(nil)
            return
        }
        refreshOverlay()
        overlayPanel.alphaValue = 0
        overlayPanel.orderFrontRegardless()
        animate(overlayPanel, alpha: coordinator.settings.settings.overlayOpacity, scaleFrom: 0.96)
    }

    private func hideOverlay() {
        coordinator.settings.settings.overlayVisible = false
        animate(overlayPanel, alpha: 0, scaleFrom: 1) { [weak self] in
            Task { @MainActor in
                guard let self, !self.coordinator.settings.settings.overlayVisible || self.settingsPresented else { return }
                self.overlayPanel.orderOut(nil)
            }
        }
    }

    private func toggleOverlay() {
        if settingsPresented { presentSettings(section: .sessions) }
        else { overlayPanel.isVisible ? hideOverlay() : showOverlay() }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsPresented = false
        if coordinator.settings.settings.overlayVisible { showOverlay() }
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioningPanels, let panel = notification.object as? NSPanel, panel.isVisible else { return }
        if panel === overlayPanel, !draggingOverlay { coordinator.settings.settings.overlayOrigin = panel.frame.origin }
        if panel === mascotPanel, !draggingMascot { coordinator.settings.settings.mascotOrigin = panel.frame.origin }
    }

    // MARK: Windows

    @objc private func toggleOverlayAction() { toggleOverlay() }

    @objc private func showSettings() { presentSettings() }
    @objc private func showSessions() { presentSettings(section: .sessions) }
    @objc private func showProjects() { presentSettings(section: .projects) }

    private func presentSettings(section: SettingsSection = .general) {
        settingsPresented = true
        overlayPanel.orderOut(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Impostazioni di Orbit"
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 8 / 255, green: 10 / 255, blue: 12 / 255, alpha: 1)
            w.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator, section: section))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        } else {
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator, section: section))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showOnboardingAction() { showOnboarding() }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: OnboardingView(coordinator: coordinator) { [weak self] in self?.onboardingWindow?.close() })
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Orbit",
                                                     .applicationVersion: "0.1",
                                                     .credits: NSAttributedString(string: "Lavora sui tuoi progetti con la voce. Codex, Ollama, LM Studio e Claude Code.")])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Debug aid: write PNGs of the pill and overlay into the logs folder.
    private func snapshotPanels() {
        var targets: [(String, NSWindow)] = [("pill", pillPanel), ("overlay", overlayPanel)]
        if let mascotPanel { targets.append(("mascot", mascotPanel)) }
        if let w = onboardingWindow { targets.append(("onboarding", w)) }
        if let w = settingsWindow { targets.append(("settings", w)) }
        for (name, panel) in targets {
            guard let v = panel.contentView else { continue }
            AppLog.write("snapshot \(name): visible=\(panel.isVisible) frame=\(panel.frame) bounds=\(v.bounds) alpha=\(panel.alphaValue)")
            guard v.bounds.width > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { AppLog.write("snapshot \(name): no rep"); continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
            if let tiff = img.tiffRepresentation, let b = NSBitmapImageRep(data: tiff), let png = b.representation(using: .png, properties: [:]) {
                do { try png.write(to: AppPaths.logs.appendingPathComponent("\(name).png")) } catch { AppLog.write("snapshot write failed \(error)") }
            } else { AppLog.write("snapshot \(name): png failed") }
        }
    }

    /// `orbit://say?text=...` — feed a transcript without the mic (scripting / testing hook).
    /// `orbit://overlay` toggles the overlay.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        for url in urls {
            AppLog.write("open url: \(url)")
            switch url.host {
            case "say":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? ""
                guard !text.isEmpty else { continue }
                coordinator.pill.state = .thinking; coordinator.pill.transcript = text; coordinator.pill.visible = true; refreshPill()
                Task { await coordinator.handle(transcript: text) }
            case "overlay": toggleOverlay()
            case "snapshot": snapshotPanels()
            case "mascot3d": Orbit3DPreviewWindow.shared.show()
            case "settings":
                let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "section" }?.value
                presentSettings(section: value.flatMap(SettingsSection.init(rawValue:)) ?? .general)
            case "onboarding": showOnboarding()
            case "permissions":
                // Debug aid: ask for mic + speech and log what TCC answers.
                AppLog.write("permissions: mic=\(SpeechService.micStatus.rawValue) speech=\(SpeechService.speechStatus.rawValue)")
                Task { let r = await SpeechService.requestPermissions(); AppLog.write("permissions result: mic=\(r.mic) speech=\(r.speech)") }
            default: break
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = coordinator.sessions.running.count
        if running > 0 {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = running == 1 ? "Una sessione è ancora in corso" : "\(running) sessioni sono ancora in corso"
            a.informativeText = running == 1 ? "Se esci si ferma." : "Se esci si fermano."
            a.addButton(withTitle: "Esci e ferma"); a.addButton(withTitle: "Annulla")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        coordinator.prepareForQuit()
        return .terminateNow
    }
}
