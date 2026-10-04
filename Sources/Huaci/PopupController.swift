import AppKit
import HuaciCore
import SwiftUI

/// Borderless panel that takes key focus (for Esc) without activating the app,
/// so the source app stays frontmost.
final class PopupPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class PopupController: TranslationPresenter {
    private unowned let model: AppModel
    private let state = PopupState()
    private var panel: PopupPanel?
    private var hostingView: NSHostingView<PopupView>?
    private var anchor: CGPoint = .zero
    private var monitors: [Any] = []

    init(model: AppModel) {
        self.model = model
    }

    /// Records the mouse position when the hotkey fires.
    func prepare(anchor: CGPoint) {
        self.anchor = anchor
    }

    // MARK: TranslationPresenter

    func showLoading(requestID: UUID, sourceText: String) {
        state.copied = false
        state.content = .loading(sourceText)
        present()
    }

    func show(result: TranslationResult, requestID: UUID) {
        state.copied = false
        state.isFavorite = model.isFavorite(result)
        state.content = .result(result)
        present()
    }

    func show(error: FlowError, requestID: UUID) {
        state.content = .error(error)
        present()
    }

    // MARK: Window

    func close() {
        guard let panel, panel.isVisible else { return }
        model.cancelTranslation()
        model.speech.stop()
        removeMonitors()
        panel.orderOut(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        updateFrame()
        if !panel.isVisible {
            panel.orderFrontRegardless()
            installMonitors()
        }
        panel.makeKey()
        // SwiftUI applies the new state on the next pass; size again afterwards.
        DispatchQueue.main.async { [weak self] in self?.updateFrame() }
    }

    private func makePanel() -> PopupPanel {
        let panel = PopupPanel(
            contentRect: CGRect(x: 0, y: 0, width: PopupView.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onCancel = { [weak self] in self?.close() }

        let hostingView = NSHostingView(rootView: PopupView(state: state, actions: makeActions()))
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }

    /// Sizes the panel to the SwiftUI content and keeps it on screen.
    private func updateFrame() {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let screens = NSScreen.screens.map(\.visibleFrame)
        let frame = PopupPositioner.frame(size: size, mouse: anchor, screens: screens)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(global)
        }
        // Clicks in this app's other windows, and Esc while the panel is key.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, event.window === panel {
                    self.close()
                    return nil
                }
                return event
            }
            if event.window !== panel { self.close() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func makeActions() -> PopupActions {
        PopupActions(
            copy: { [weak self] text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.state.copied = true
            },
            speak: { [weak self] text, language in self?.model.speech.speak(text, language: language) },
            toggleFavorite: { [weak self] result in
                guard let self else { return }
                self.state.isFavorite = self.model.toggleFavorite(result)
            },
            retry: { [weak self] in self?.model.retry() },
            close: { [weak self] in self?.close() },
            openSettings: { [weak self] in
                self?.close()
                WindowRouter.shared.showSettings()
            },
            openAccessibility: { [weak self] in
                self?.close()
                SystemSelectionEnvironment.requestAccessibilityPrompt()
                SystemSelectionEnvironment.openAccessibilitySettings()
            }
        )
    }
}
