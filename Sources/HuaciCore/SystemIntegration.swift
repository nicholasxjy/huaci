import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// `NSPasteboard.general` adapter for `SelectionCapturer`.
public final class SystemPasteboard: PasteboardAccess {
    /// Larger clipboards are not copied into memory; copy-based capture is skipped instead.
    static let maxSnapshotBytes = 64 * 1024 * 1024

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> PasteboardSnapshot? {
        var total = 0
        var items: [[PasteboardSnapshot.Entry]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [PasteboardSnapshot.Entry] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= Self.maxSnapshotBytes else { return nil }
                entries.append(.init(type: type.rawValue, data: data))
            }
            items.append(entries)
        }
        return PasteboardSnapshot(items: items)
    }

    public func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    public func readString() -> String? {
        pasteboard.string(forType: .string)
    }
}

/// Accessibility and keyboard-event access to other apps.
@MainActor
public final class SystemSelectionEnvironment: SelectionEnvironment {
    public init() {}

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func readSelectedText(pid: pid_t) -> AccessibilityReadResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .unavailable
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) {
        case .success:
            guard let text = value as? String else { return .empty }
            return text.isEmpty ? .empty : .text(text)
        case .noValue, .attributeUnsupported:
            return .empty
        default:
            return .unavailable
        }
    }

    public func waitForModifierRelease() async {
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<25 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            await sleep(milliseconds: 20)
        }
    }

    public func sendCopyCommand() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    public func sleep(milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    /// Shows the system prompt that lists this app under Accessibility.
    public static func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
