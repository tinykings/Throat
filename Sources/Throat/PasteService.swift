import AppKit
import ApplicationServices
import Carbon

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
    static func paste(_ text: String, into target: NSRunningApplication?, completion: @escaping (String?) -> Void) {
        guard let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion("Click into a text field first. Your transcript is available from the menu.")
            return
        }
        attempt(text, target: target, remaining: 20, completion: completion)
    }

    private static func attempt(_ text: String, target: NSRunningApplication, remaining: Int,
                                completion: @escaping (String?) -> Void) {
        guard isTrusted else {
            completion("Turn on Accessibility in Throat Settings to paste automatically. Your text is kept in the menu.")
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            completion("Focus changed, so nothing was pasted. Use Copy Last Transcript in the menu.")
            return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
            guard remaining > 0 else { completion("Release the shortcut keys, then use Copy Last Transcript in the menu."); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                attempt(text, target: target, remaining: remaining - 1, completion: completion)
            }
            return
        }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == (kAXSecureTextFieldSubrole as String) {
                completion("Pasting into password fields is disabled.")
                return
            }
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            completion("Could not create a paste event. Use Copy Last Transcript in the menu.")
            return
        }
        let clipboard = NSPasteboard.general
        // Do not inspect/read other apps' clipboard data: macOS may prompt for data access.
        // Keep the dictated text on the clipboard for recovery instead of restoring old contents.
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        completion(nil)
    }
}
