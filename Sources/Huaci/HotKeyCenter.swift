import Carbon.HIToolbox
import HuaciCore

enum HotKeyError: Error, Equatable {
    case invalid
    case takenBySystem
    case registrationFailed(OSStatus)

    var message: String {
        switch self {
        case .invalid:
            return "快捷键需要包含 ⌘、⌥ 或 ⌃ 中的至少一个。"
        case .takenBySystem:
            return "该快捷键已被系统快捷键占用，请换一个组合。"
        case .registrationFailed(let status) where status == eventHotKeyExistsErr:
            return "该快捷键已被其他应用占用，请换一个组合。"
        case .registrationFailed(let status):
            return "快捷键注册失败（\(status)），请换一个组合。"
        }
    }
}

/// System-wide hotkey through Carbon's `RegisterEventHotKey`, which needs no
/// extra permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ shortcut: Shortcut) -> Result<Void, HotKeyError> {
        unregister()
        guard shortcut.isValid else { return .failure(.invalid) }
        guard !Self.isTakenBySystem(shortcut) else { return .failure(.takenBySystem) }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4855_4143), id: 1) // "HUAC"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return .failure(.registrationFailed(status)) }
        hotKeyRef = ref
        return .success(())
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyCenter.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Checks enabled shortcuts in System Settings › Keyboard › Shortcuts.
    static func isTakenBySystem(_ shortcut: Shortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        let mask: UInt32 = 0x0100 | 0x0200 | 0x0800 | 0x1000
        return array.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return UInt32(code) == shortcut.keyCode && UInt32(modifiers) & mask == shortcut.carbonModifiers
        }
    }
}
