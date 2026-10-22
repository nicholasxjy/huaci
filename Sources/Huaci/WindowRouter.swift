import AppKit
import SwiftUI

/// Opens the app's regular windows: the main window, settings and onboarding.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    weak var model: AppModel?
    private var windows: [String: NSWindow] = [:]
    private var settingsController: SettingsTabController?

    /// The "划词" window with translate, history and vocabulary.
    func showMain(_ section: MainSection? = nil) {
        guard let model else { return }
        if let section { model.mainWindow.section = section }
        let window = windows["main"] ?? makeWindow(
            id: "main", title: "划词", size: CGSize(width: 1040, height: 700), minSize: CGSize(width: 860, height: 560),
            style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            content: MainWindowView(state: model.mainWindow)
                .environmentObject(model)
                .environmentObject(model.settings)
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        bringToFront(window)
    }

    func showSettings(_ tab: SettingsTab? = nil) {
        guard let model else { return }
        let window: NSWindow
        if let existing = windows["settings"] {
            window = existing
        } else {
            let controller = SettingsTabController(model: model)
            window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("Huaci.settings")
            // Keep only the saved position; older versions saved a smaller size.
            window.setContentSize(SettingsTabController.contentSize)
            settingsController = controller
            windows["settings"] = window
        }
        settingsController?.select(tab ?? currentSettingsTab ?? .general)
        bringToFront(window)
    }

    func showOnboarding() {
        guard let model else { return }
        let window = windows["onboarding"] ?? makeWindow(
            id: "onboarding", title: "欢迎使用划词", size: CGSize(width: 720, height: 640), minSize: nil,
            style: [.titled, .closable, .fullSizeContentView],
            content: OnboardingView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .tint(Theme.accent)
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        bringToFront(window)
    }

    func close(id: String) {
        windows[id]?.close()
    }

    private var currentSettingsTab: SettingsTab? {
        guard let controller = settingsController, controller.view.window?.isVisible == true,
              let identifier = controller.tabViewItems[controller.selectedTabViewItemIndex].identifier as? String
        else { return nil }
        return SettingsTab(rawValue: identifier)
    }

    private func makeWindow<Content: View>(id: String, title: String, size: CGSize, minSize: CGSize?,
                                           style: NSWindow.StyleMask, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: content)
        // The window decides the size; SwiftUI content would otherwise grow it to fit every row.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        if let minSize { window.contentMinSize = minSize }
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("Huaci.\(id)")
        // A fixed-size window keeps only its saved position; older versions saved other sizes.
        if !style.contains(.resizable) { window.setContentSize(size) }
        windows[id] = window
        return window
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
