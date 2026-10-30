import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, preparing, recording, finishing, delivering, message }
    private var state = State.idle
    private let hotKey = HotKey()
    /// Registered only while recording, so Escape reaches other apps normally the rest of the time.
    private let escapeKey = HotKey(id: 2)
    private var pasteWhenDone = true
    private let recorder = SpeechRecorder()
    private let panel = TranscriptPanel()
    private var statusItem: NSStatusItem!
    private var shortcut = Shortcut.saved
    private var transcript = TranscriptBuffer()
    private var text: String { transcript.text }
    private var lastTranscript = ""
    private var target: NSRunningApplication?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var finishTimeout: DispatchWorkItem?
    private var earliestDelivery = Date.distantPast
    private var generation = UUID()
    private lazy var settings: SettingsWindowController = {
        let model = SettingsModel(shortcut: shortcut)
        model.onShortcutChange = { [weak self] candidate in
            guard let self else { return false }
            guard self.hotKey.register(candidate) else { return false }
            self.shortcut = candidate
            self.shortcut.save()
            self.updateIcon()
            return true
        }
        // Pause the global shortcut while recording a new one so it doesn't start dictation.
        model.onRecordingChange = { [weak self] recording in
            guard let self else { return }
            if recording { self.cancel(); self.hotKey.unregister() } else { self.hotKey.register(self.shortcut) }
        }
        return SettingsWindowController(model: model)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        panel.onCancel = { [weak self] in self?.cancel() }
        recorder.onText = { [weak self] segment, text in
            guard let self, self.state == .recording || self.state == .finishing else { return }
            self.transcript.update(text, segment: segment)
        }
        recorder.onLevel = { [weak self] level in
            guard let self, self.state == .recording else { return }
            self.panel.push(level: level)
        }
        recorder.onEnd = { [weak self] error in
            guard let self else { return }
            if self.state == .finishing { self.deliver() }
            else if self.state == .recording {
                // The recorder handles pauses itself, so ending while recording means recognition failed.
                self.lastTranscript = self.text
                let reason = error?.localizedDescription ?? "Speech recognition stopped unexpectedly."
                self.showMessage(reason + (self.text.isEmpty ? "" : " Your text is kept in Copy Last Transcript."))
            }
        }
        hotKey.onPress = { [weak self] in self?.toggle() }
        escapeKey.onPress = { [weak self] in self?.stop(paste: false) }
        let registered = hotKey.register(shortcut)
        if !registered { settings.model.shortcutError = "\(shortcut.label) is already in use by another app. Choose a new shortcut." }
        // Walk through setup on first launch, and whenever something still needs allowing.
        if !UserDefaults.standard.bool(forKey: "didShowSettings") || !Permission.allGranted || !registered {
            UserDefaults.standard.set(true, forKey: "didShowSettings")
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Throat", action: nil, keyEquivalent: "")
        menu.addItem(title)
        let active = state == .recording
        add(menu, active ? "Stop & Paste  \(shortcut.label)" : "Start Dictation  \(shortcut.label)", #selector(toggleFromMenu))
        menu.addItem(.separator())
        let copy = add(menu, "Copy Last Transcript", #selector(copyLast))
        copy.isEnabled = !lastTranscript.isEmpty
        add(menu, Permission.allGranted ? "Settings…" : "Settings…  ⚠︎ Permissions needed", #selector(showSettings))
        menu.addItem(.separator())
        add(menu, "Quit Throat", #selector(quit))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleFromMenu() {
        // Let the menu finish dismissing before recording or delivering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.toggle() }
    }

    private func toggle() {
        switch state {
        case .idle, .message: start()
        case .recording: stop(paste: true)
        case .preparing: cancel()
        case .finishing, .delivering: break
        }
    }

    private func start() {
        cancel()
        // Accessibility is needed only for paste, never for microphone capture.
        state = .preparing
        panel.show(.preparing, shortcut: shortcut.label)
        if SpeechRecorder.willRequestPermission { NSApp.activate(ignoringOtherApps: true) }
        let id = generation
        Task { @MainActor in
            do { try await SpeechRecorder.authorize() }
            catch {
                guard self.generation == id, self.state == .preparing else { return }
                self.cancel()
                self.showSettings()
                return
            }
            guard self.generation == id, self.state == .preparing else { return }
            self.transcript = TranscriptBuffer()
            do {
                try self.recorder.start()
                self.state = .recording
                self.panel.show(.listening, shortcut: self.shortcut.label)
                self.escapeKey.register(.escape)
                self.updateIcon()
            } catch { self.showMessage(error.localizedDescription) }
        }
    }

    /// Finishes recognition, then pastes into the frontmost app or only copies to the clipboard.
    private func stop(paste: Bool) {
        guard state == .recording else { return }
        escapeKey.unregister()
        pasteWhenDone = paste
        target = NSWorkspace.shared.frontmostApplication
        state = .finishing
        // Let shortcut/menu events settle before sending Command-V.
        earliestDelivery = Date().addingTimeInterval(0.2)
        removeClickMonitors()
        panel.show(paste ? .finishing : .copying, shortcut: shortcut.label)
        recorder.finish()
        let timeout = DispatchWorkItem { [weak self] in self?.deliver() }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    private func deliver() {
        guard state == .finishing else { return }
        let delay = earliestDelivery.timeIntervalSinceNow
        if delay > 0 {
            let id = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.generation == id else { return }
                self.deliver()
            }
            return
        }
        finishTimeout?.cancel()
        recorder.cancel()
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { cancel(); return }
        lastTranscript = transcript
        guard pasteWhenDone else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            showCopied()
            return
        }
        guard PasteService.isTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            showMessage("Transcript copied. Press ⌘V to paste it. To paste automatically, allow Accessibility in Throat Settings.")
            return
        }
        state = .delivering
        panel.orderOut(nil)
        let id = generation
        PasteService.paste(transcript, into: target) { [weak self] outcome in
            guard let self, self.generation == id else { return }
            switch outcome {
            case .pasted: self.cancel()
            case .copied: self.showCopied()
            case .failed(let error): self.showMessage(error)
            }
        }
    }

    private func installClickMonitors() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.clickedAway()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.clickedAway() }
            return event
        }
    }

    private func clickedAway() {
        // Only informational messages dismiss on click-away. Dictation continues in the background.
        if state == .message { cancel() }
    }

    private func removeClickMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        mouseMonitor = nil
        localMonitor = nil
    }

    private func showMessage(_ message: String) {
        cancel()
        state = .message
        panel.show(.message(message), shortcut: shortcut.label)
        installClickMonitors()
    }

    private func showCopied() {
        state = .delivering
        panel.show(.copied, shortcut: shortcut.label)
        let id = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.generation == id else { return }
            self.cancel()
        }
    }

    private func cancel() {
        generation = UUID()
        escapeKey.unregister()
        finishTimeout?.cancel()
        finishTimeout = nil
        recorder.cancel()
        removeClickMonitors()
        panel.orderOut(nil)
        state = .idle
        updateIcon()
    }

    private func updateIcon() {
        statusItem?.button?.image = MenuBarIcon.image
        // Fade out while recording so it doesn't duplicate the system mic indicator; keeps its slot so neighbours don't shift.
        statusItem?.button?.alphaValue = state == .recording ? 0 : 1
        statusItem?.button?.toolTip = "Throat — \(shortcut.label) to dictate"
    }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }
    @objc private func showSettings() {
        settings.model.shortcut = shortcut
        settings.show()
    }
    @objc private func quit() { cancel(); NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) { recorder.cancel() }
}
