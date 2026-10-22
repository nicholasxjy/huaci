import AppKit
import HuaciCore
import SwiftUI

/// Click, then press a key combination. Esc cancels, ⌫ restores the default.
struct ShortcutRecorder: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                recording ? stop(restore: true) : start()
            } label: {
                Group {
                    if recording {
                        Text("请按下新的快捷键…").font(.system(size: 13)).foregroundStyle(Theme.accent).frame(minWidth: 130)
                    } else {
                        KeyCaps(shortcut: settings.shortcut)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 36)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(recording ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: recording ? 2 : 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "按 Esc 取消" : "点击后按下新的组合键")
            .accessibilityLabel(recording ? "正在录制快捷键" : "快捷键 \(settings.shortcut.displayString)，点击修改")
            if let message = message ?? model.hotKeyError {
                Text(message).font(.caption).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
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
            switch event.keyCode {
            case 53:
                stop(restore: true)
                return nil
            case 51:
                stop(restore: false)
                apply(.defaultShortcut)
                return nil
            default:
                break
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
