//
//  GlobalShortcutManager.swift
//  SideCli
//

import Carbon
import AppKit
import Combine

class GlobalShortcutManager: ObservableObject {

    @Published var keyCode: Int
    @Published var modifierFlags: NSEvent.ModifierFlags

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private static let keyCodeKey    = "shortcut.keyCode"
    private static let modifiersKey  = "shortcut.modifiers"
    private static let defaultKeyCode    = 50              // kVK_ANSI_Grave  → `
    private static let defaultModifiers: NSEvent.ModifierFlags = .command

    init() {
        keyCode = UserDefaults.standard.object(forKey: Self.keyCodeKey) as? Int
            ?? Self.defaultKeyCode

        let raw = UserDefaults.standard.object(forKey: Self.modifiersKey) as? Int
        modifierFlags = raw.map { NSEvent.ModifierFlags(rawValue: UInt($0)) }
            ?? Self.defaultModifiers
    }

    // MARK: - Registration

    func register() {
        installEventHandler()
        registerHotKey()
    }

    func updateShortcut(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        unregisterHotKey()
        self.keyCode = keyCode
        self.modifierFlags = modifiers
        UserDefaults.standard.set(keyCode,              forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: Self.modifiersKey)
        registerHotKey()
    }

    // MARK: - Private

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let mgr = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { mgr.onTrigger?() }
            return noErr
        }, 1, &spec, ptr, &eventHandlerRef)
    }

    private func registerHotKey() {
        let carbonMods = carbonModifiers(from: modifierFlags)
        let hotKeyID   = EventHotKeyID(signature: 0x5343_4C49, id: 1)   // 'SCLI'
        let status = RegisterEventHotKey(UInt32(keyCode), carbonMods, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { print("GlobalShortcutManager: register failed \(status)") }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey)     }
        if flags.contains(.option)  { m |= UInt32(optionKey)  }
        if flags.contains(.shift)   { m |= UInt32(shiftKey)   }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    // MARK: - Display

    var displayString: String { shortcutDisplayString(keyCode: keyCode, modifiers: modifierFlags) }

    deinit {
        unregisterHotKey()
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }
}

// MARK: - Helpers (file-level, used by SettingsView too)

func shortcutDisplayString(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
    var s = ""
    if modifiers.contains(.control) { s += "⌃" }
    if modifiers.contains(.option)  { s += "⌥" }
    if modifiers.contains(.shift)   { s += "⇧" }
    if modifiers.contains(.command) { s += "⌘" }
    s += virtualKeyCodeToString(keyCode)
    return s
}

func virtualKeyCodeToString(_ keyCode: Int) -> String {
    let map: [Int: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X",
        8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R",
        16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6",
        23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0",
        30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P",
        37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",",
        44:"/", 45:"N", 46:"M", 47:".", 49:"Space",
        50:"`", 96:"F5", 97:"F6", 98:"F7", 99:"F3",
        100:"F8", 101:"F9", 103:"F11", 109:"F10", 111:"F12",
        115:"Home", 116:"PgUp", 117:"⌦", 118:"F4",
        119:"End", 120:"F2", 121:"PgDn", 122:"F1",
        123:"←", 124:"→", 125:"↓", 126:"↑"
    ]
    return map[keyCode] ?? "?"
}
