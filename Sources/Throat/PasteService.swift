import AppKit
import ApplicationServices
import Carbon

enum PasteOutcome: Equatable {
    case pasted
    /// No text field was focused, so the text was only put on the clipboard.
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

    /// Never activates an app or sends Return. Abort if focus changes while waiting.
    /// Falls back to copying when no text field is focused.
    static func paste(_ text: String, into target: NSRunningApplication?, completion: @escaping (PasteOutcome) -> Void) {
        guard let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            copy(text)
            completion(.copied)
            return
        }
        attempt(text, target: target, remaining: 20, completion: completion)
    }

    private static func attempt(_ text: String, target: NSRunningApplication, remaining: Int,
                                completion: @escaping (PasteOutcome) -> Void) {
        guard isTrusted else {
            completion(.failed("Turn on Accessibility in Throat Settings to paste automatically. Your text is kept in the menu."))
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            completion(.failed("Focus changed, so nothing was pasted. Use Copy Last Transcript in the menu."))
            return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
            guard remaining > 0 else { completion(.failed("Release the shortcut keys, then use Copy Last Transcript in the menu.")); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                attempt(text, target: target, remaining: remaining - 1, completion: completion)
            }
            return
        }
        switch focusedField(in: target) {
        case .secure:
            completion(.failed("Pasting into password fields is disabled."))
            return
        case .none:
            copy(text)
            completion(.copied)
            return
        case .editable, .unknown:
            break
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            completion(.failed("Could not create a paste event. Use Copy Last Transcript in the menu."))
            return
        }
        // Do not inspect/read other apps' clipboard data: macOS may prompt for data access.
        // Keep the dictated text on the clipboard for recovery instead of restoring old contents.
        copy(text)
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

    private enum FocusedField { case editable, secure, none, unknown }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// `.unknown` when the app doesn't expose Accessibility; paste anyway rather than guess.
    private static func focusedField(in target: NSRunningApplication) -> FocusedField {
        let app = AXUIElementCreateApplication(target.processIdentifier)
        // Electron/Chromium apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) {
        case .success: break
        case .noValue: return .none
        default: return .unknown
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .none }
        let element = focused as! AXUIElement
        if (string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole) { return .secure }
        if let role = string(element, kAXRoleAttribute), textRoles.contains(role) { return .editable }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           (editable as? Bool) == true {
            return .editable
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }
        return .none
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }
}
