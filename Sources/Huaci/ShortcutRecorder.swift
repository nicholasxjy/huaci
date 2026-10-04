import AppKit
import HuaciCore
import SwiftUI

/// Click, then press a key combination. Esc cancels.
struct ShortcutRecorder: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(recording ? "请按下新的快捷键…" : settings.shortcut.displayString) {
                    recording ? stop(restore: true) : start()
                }
                .frame(minWidth: 140)
                if settings.shortcut != .defaultShortcut {
                    Button("恢复默认") { apply(.defaultShortcut) }
                }
            }
            if let message = message ?? model.hotKeyError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop(restore: true) }
    }

    private func start() {
        message = nil
        recording = true
        // Unregister so pressing the current shortcut is recorded instead of triggering it.
        model.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop(restore: true)
                return nil
            }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event.modifierFlags))
            guard shortcut.isValid else {
                message = "快捷键需要包含 ⌘、⌥ 或 ⌃ 中的至少一个。"
                return nil
            }
            stop(restore: false)
            apply(shortcut)
            return nil
        }
    }

    private func stop(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording && restore { model.registerSavedShortcut() }
        recording = false
    }

    private func apply(_ shortcut: Shortcut) {
        let previous = settings.shortcut
        if let error = model.applyShortcut(shortcut) {
            model.applyShortcut(previous)
            message = "\(error.message)已保留原快捷键 \(previous.displayString)。"
        } else {
            message = nil
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
