import AppKit
import SwiftUI

/// Opens the app's regular windows from the menu bar item.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    weak var model: AppModel?
    private var windows: [String: NSWindow] = [:]

    func showSettings() {
        guard let model else { return }
        show(id: "settings", title: "划词设置", size: CGSize(width: 560, height: 480)) {
            SettingsView().environmentObject(model).environmentObject(model.settings)
        }
    }

    func showInputTranslation() {
        guard let model else { return }
        show(id: "input", title: "输入翻译", size: CGSize(width: 520, height: 480)) {
            InputTranslationView(state: model.inputTranslation).environmentObject(model)
        }
    }

    func showHistory() {
        guard let model else { return }
        show(id: "history", title: "查询历史", size: CGSize(width: 760, height: 520)) {
            HistoryView().environmentObject(model)
        }
    }

    func showVocabulary() {
        guard let model else { return }
        show(id: "vocabulary", title: "生词本", size: CGSize(width: 760, height: 520)) {
            VocabularyView().environmentObject(model)
        }
    }

    func showOnboarding() {
        guard let model else { return }
        show(id: "onboarding", title: "欢迎使用划词", size: CGSize(width: 560, height: 520)) {
            OnboardingView().environmentObject(model).environmentObject(model.settings)
        }
    }

    func close(id: String) {
        windows[id]?.close()
    }

    private func show<Content: View>(id: String, title: String, size: CGSize, @ViewBuilder content: () -> Content) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.isReleasedWhenClosed = false
            let hostingView = NSHostingView(rootView: content())
            // The window decides the size; SwiftUI content would otherwise grow it to fit every row.
            hostingView.sizingOptions = []
            window.contentView = hostingView
            window.contentMinSize = CGSize(width: 480, height: 400)
            window.setContentSize(size)
            window.center()
            window.setFrameAutosaveName("Huaci.\(id)")
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
