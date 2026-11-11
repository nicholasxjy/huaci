import AppKit
import HuaciCore
import SwiftUI

/// Owns one recording window and releases the suspended hotkey exactly once.
@MainActor
final class ShortcutRecordingSession: ObservableObject {
    typealias EventHandler = (NSEvent) -> NSEvent?
    typealias InstallMonitor = (@escaping EventHandler) -> Any?
    private static weak var active: ShortcutRecordingSession?
    @Published private(set) var isRecording = false
    private weak var owner: AnyObject?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onStop: ((Bool) -> Void)?

    func begin(owner: AnyObject, onStop: @escaping (Bool) -> Void) {
        Self.active?.stop()
        self.owner = owner
        self.onStop = onStop
        Self.active = self
        isRecording = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    func start(window: NSWindow, suspend: () -> Void, restore: @escaping () -> Void,
               installMonitor: InstallMonitor = { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) },
               receive: @escaping (NSEvent) -> Void) {
        begin(owner: window) { shouldRestore in if shouldRestore { restore() } }
        suspend()
        monitor = installMonitor { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard self.owns(event.window) else {
                self.stop()
                return event
            }
            receive(event)
            return nil
        }
        if monitor == nil { stop() }
    }

    func owns(_ window: AnyObject?) -> Bool {
        isRecording && owner != nil && owner === window
    }

    func stop(restore: Bool = true) {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isRecording = false
        owner = nil
        if Self.active === self { Self.active = nil }
        let callback = onStop
        onStop = nil
        callback?(restore)
    }
}

/// Click, then press a key combination. Esc cancels, ⌫ restores the default.
struct ShortcutRecorder: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var session = ShortcutRecordingSession()
    @State private var window: NSWindow?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                session.isRecording ? session.stop() : start()
            } label: {
                Group {
                    if session.isRecording {
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
                        .strokeBorder(session.isRecording ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: session.isRecording ? 2 : 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.isRecording ? "按 Esc 取消" : "点击后按下新的组合键")
            .accessibilityLabel(session.isRecording ? "正在录制快捷键，按 Esc 取消" : "快捷键 \(settings.shortcut.displayString)，点击修改")
            .background(RecorderWindowReader { window = $0 })
            if let message = message ?? model.hotKeyError {
                Text(message).font(.caption).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { session.stop() }
    }

    private func start() {
        guard let window, window.isKeyWindow else { return }
        message = nil
        session.start(window: window, suspend: model.suspendHotKey, restore: {
            if let error = model.applyShortcut(settings.shortcut) { AccessibilityAnnouncement.post(error.message) }
        }) { event in
            switch event.keyCode {
            case 53:
                session.stop()
                return
            case 51:
                session.stop(restore: false)
                apply(.defaultShortcut)
                return
            default:
                break
            }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event.modifierFlags))
            guard shortcut.isValid else {
                let error = "快捷键需要包含 ⌘、⌥ 或 ⌃ 中的至少一个。"
                message = error
                AccessibilityAnnouncement.post(error)
                return
            }
            session.stop(restore: false)
            apply(shortcut)
        }
        AccessibilityAnnouncement.post("正在录制快捷键，按 Esc 取消。")
    }

    private func apply(_ shortcut: Shortcut) {
        message = Self.apply(shortcut, previous: settings.shortcut, register: model.applyShortcut)
        AccessibilityAnnouncement.post(message ?? "快捷键已更新。")
    }

    static func apply(_ shortcut: Shortcut, previous: Shortcut, register: (Shortcut) -> HotKeyError?) -> String? {
        guard let error = register(shortcut) else { return nil }
        if let rollback = register(previous) {
            return "\(error.message)原快捷键也未能恢复：\(rollback.message)请重新设置快捷键。"
        }
        return "\(error.message)已恢复原快捷键 \(previous.displayString)。"
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

private struct RecorderWindowReader: NSViewRepresentable {
    var update: (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowView { WindowView(update: update) }
    func updateNSView(_ nsView: WindowView, context: Context) { nsView.update = update }

    final class WindowView: NSView {
        var update: (NSWindow?) -> Void
        init(update: @escaping (NSWindow?) -> Void) {
            self.update = update
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [weak self] in self?.update(window) }
        }
    }
}
