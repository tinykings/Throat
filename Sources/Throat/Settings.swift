import AppKit
import AVFoundation
import Carbon
import Speech
import SwiftUI

enum Permission: CaseIterable, Identifiable {
    case microphone, speech, accessibility
    enum Access { case allowed, notAsked, denied }

    var id: Self { self }
    static var allGranted: Bool { allCases.allSatisfy { $0.access == .allowed } }

    var access: Access {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .allowed
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .allowed
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .accessibility:
            return PasteService.isTrusted ? .allowed : .notAsked
        }
    }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        case .accessibility: "Accessibility"
        }
    }

    var detail: String {
        switch self {
        case .microphone: "Hear your voice while you dictate."
        case .speech: "Turn speech into text, on device when possible."
        case .accessibility: "Paste the text into the app you're using."
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .speech: "waveform"
        case .accessibility: "keyboard.fill"
        }
    }

    var tint: Color {
        switch self {
        case .microphone: .red
        case .speech: .purple
        case .accessibility: .blue
        }
    }

    /// Asks macOS directly the first time; afterwards only System Settings can change the answer.
    func request(completion: @escaping () -> Void) {
        let done = { DispatchQueue.main.async(execute: completion) }
        switch (self, access) {
        case (.microphone, .notAsked): AVCaptureDevice.requestAccess(for: .audio) { _ in done() }
        case (.speech, .notAsked): SFSpeechRecognizer.requestAuthorization { _ in done() }
        case (.accessibility, _) where PasteService.requestPermission(): done()
        default: openSystemSettings()
        }
    }

    func openSystemSettings() {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .accessibility: "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var shortcut: Shortcut
    @Published var isRecording = false
    @Published var shortcutError: String?
    @Published private(set) var access: [Permission: Permission.Access] = [:]
    /// Returns false when the shortcut could not be registered.
    var onShortcutChange: ((Shortcut) -> Bool)?
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        refresh()
    }

    func refresh() {
        let current = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.access) })
        if current != access { access = current }
    }

    func allow(_ permission: Permission) {
        permission.request { [weak self] in self?.refresh() }
    }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        shortcutError = nil
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    func endRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        onRecordingChange?(false)
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { endRecording(); return }
        guard let candidate = Shortcut(event: event) else {
            shortcutError = "Include ⌘, ⌃, or ⌥ in the shortcut."
            return
        }
        if onShortcutChange?(candidate) == true {
            shortcut = candidate
            shortcutError = nil
        } else {
            shortcutError = "\(candidate.label) is already in use. Your previous shortcut was kept."
        }
        endRecording()
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private var timer: Timer?

    init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Throat Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        model.refresh()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // macOS posts no notification for Accessibility changes, so poll while the window is open.
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        model.endRecording()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var missing: Int { model.access.values.filter { $0 != .allowed }.count }

    var body: some View {
        Form {
            Section {
                header
            }
            Section {
                LabeledContent {
                    shortcutButton
                } label: {
                    Text("Dictation shortcut")
                    Text("Press it anywhere to start, and again to paste. Press esc to copy instead.")
                }
                if let error = model.shortcutError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Shortcut")
            }
            Section {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, access: model.access[permission] ?? .notAsked) {
                        model.allow(permission)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                if model.access[.accessibility] != .allowed {
                    Text("Already on in System Settings but still not allowed? Remove Throat with the – button, then add it again with +.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Version \(UpdateChecker.currentVersion)") {
                    Link("View on GitHub", destination: UpdateChecker.repository)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Throat").font(.title3.weight(.semibold))
                if missing == 0 {
                    Label("Ready — press \(model.shortcut.label) to dictate", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("\(missing) permission\(missing == 1 ? "" : "s") needed", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private var shortcutButton: some View {
        Button {
            model.isRecording ? model.endRecording() : model.beginRecording()
        } label: {
            Text(model.isRecording ? "Type shortcut…" : model.shortcut.label)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 110)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(model.isRecording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(model.isRecording ? Color.accentColor : Color.primary.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.isRecording ? "Press Escape to cancel" : "Click to change")
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let access: Permission.Access
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(permission.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if access == .allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button(access == .notAsked ? "Allow" : "Open Settings…", action: allow)
                    .controlSize(.regular)
            }
        }
    }
}
