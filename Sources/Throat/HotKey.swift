import AppKit
import Carbon

struct Shortcut: Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥Space")
    static let escape = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0, label: "esc")
    static var saved: Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "shortcut"),
              let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .standard }
        return value
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "shortcut")
    }
}

extension Shortcut {
    /// A shortcut from a key press, or nil unless it includes ⌘, ⌃, or ⌥.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !event.isARepeat, !flags.contains(.function),
              !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        var label = ""
        for (flag, carbon, symbol): (NSEvent.ModifierFlags, Int, String) in [
            (.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
            (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
        ] where flags.contains(flag) {
            modifiers |= UInt32(carbon)
            label += symbol
        }
        let key = event.keyCode == UInt16(kVK_Space) ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label + key)
    }
}

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    var onPress: (() -> Void)?

    /// Each HotKey needs its own id; every instance's handler sees every hot key press.
    init(id: UInt32 = 1) {
        self.id = id
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            hotKey.onPress?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: 0x4D484F4C, id: id)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                  GetApplicationEventTarget(), 0, &reference) == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}
