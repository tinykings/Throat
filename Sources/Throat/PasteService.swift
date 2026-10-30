import AppKit
import ApplicationServices
import Carbon

enum PasteOutcome: Equatable {
    case pasted
    /// There was no other app to paste into, so the text was only put on the clipboard.
    case copied
    case failed(String)
}

final class PasteService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var hasPrompted = false

    /// Shows the macOS prompt once per launch; returns false when it was not shown.
    static func requestPermission() -> Bool {
        guard !isTrusted, !hasPrompted else { return false }
        hasPrompted = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return true
    }

    /// Always copies, then pastes into the frontmost app without checking for a text field.
    /// Never activates an app or sends Return. Abort if focus changes while waiting.
    static func paste(_ text: String, into target: NSRunningApplication?, completion: @escaping (PasteOutcome) -> Void) {
        copy(text)
        guard let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(.copied)
            return
        }
        attempt(text, target: target, remaining: 20, completion: completion)
    }

    private static func attempt(_ text: String, target: NSRunningApplication, remaining: Int,
                                completion: @escaping (PasteOutcome) -> Void) {
        guard isTrusted else {
            completion(.failed("Turn on Accessibility in Throat Settings to paste automatically. Your text is on the clipboard."))
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            completion(.failed("Focus changed, so nothing was pasted. Your text is on the clipboard."))
            return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
            guard remaining > 0 else { completion(.failed("Release the shortcut keys, then press ⌘V to paste.")); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                attempt(text, target: target, remaining: remaining - 1, completion: completion)
            }
            return
        }
        if isSecureFieldFocused(in: target) {
            completion(.failed("Pasting into password fields is disabled. Your text is on the clipboard."))
            return
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            completion(.failed("Could not paste automatically. Your text is on the clipboard."))
            return
        }
        // Do not inspect/read other apps' clipboard data: macOS may prompt for data access.
        // Keep the dictated text on the clipboard for recovery instead of restoring old contents.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        completion(.pasted)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The only focus check left: never type dictated text into a password field.
    private static func isSecureFieldFocused(in target: NSRunningApplication) -> Bool {
        let app = AXUIElementCreateApplication(target.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return string(focused as! AXUIElement, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }
}
