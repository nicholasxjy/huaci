import AppKit
import HuaciCore
import SwiftUI

/// Borderless panel that takes key focus (for Esc and the popup's shortcuts)
/// without activating the app, so the source app stays frontmost.
final class PopupPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Returns true when the event was handled.
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }
}

/// Lets a pinned panel be dragged by its background.
private final class PopupHostingView: NSHostingView<PopupView> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class PopupController: TranslationPresenter {
    private unowned let model: AppModel
    private let state = PopupState()
    private var panel: PopupPanel?
    private var hostingView: PopupHostingView?
    private var anchor: CGPoint = .zero
    private var monitors: [Any] = []
    private var hintDismissal: Task<Void, Never>?

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
        model.didShowPopupResult()
    }

    func show(error: FlowError, requestID: UUID) {
        let presentation = ErrorPresentation.make(error, shortcut: model.settings.shortcut.displayString, serviceLine: model.serviceLine)
        if presentation.isHint {
            state.content = .hint(presentation.title)
            present()
            hintDismissal = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, case .hint = self.state.content else { return }
                self.close()
            }
        } else {
            state.content = .error(error)
            present()
        }
    }

    // MARK: Window

    func close() {
        guard let panel, panel.isVisible else { return }
        hintDismissal?.cancel()
        model.cancelTranslation()
        model.speech.stop()
        removeMonitors()
        state.isPinned = false
        panel.isMovableByWindowBackground = false
        panel.orderOut(nil)
    }

    private func present() {
        hintDismissal?.cancel()
        state.modelName = model.activeModelName
        state.serviceLine = model.serviceLine
        state.shortcut = model.settings.shortcut.displayString
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
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        let hostingView = PopupHostingView(rootView: PopupView(state: state, actions: makeActions()))
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }

    /// Sizes the panel to the SwiftUI content. Unpinned panels follow the
    /// mouse; a pinned one keeps its top edge where the user left it.
    private func updateFrame() {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let frame: CGRect
        if state.isPinned && panel.isVisible {
            frame = CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        } else {
            frame = PopupPositioner.frame(size: size, mouse: anchor, screens: NSScreen.screens.map(\.visibleFrame))
        }
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.isPinned else { return }
                self.close()
            }
        }) {
            monitors.append(global)
        }
        // Clicks in this app's regular windows, and Esc while the panel is key.
        // Menus opened from the panel (the language menu) are not "outside".
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, event.window === panel {
                    self.close()
                    return nil
                }
                return event
            }
            if !self.state.isPinned, let window = event.window, window !== panel, window.level == .normal {
                self.close()
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: Actions

    /// ⌘C copy, ⌘S save, ⌘R speak, ⌘P pin, ⌘O open in the main window, ↩ the error's action.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "p":
                if case .hint = state.content { return false }
                togglePin()
                return true
            case "c", "s", "r", "o":
                guard let result = state.result else { return false }
                switch key {
                case "c": copy(result.translation)
                case "s":
                    guard result.kind == .word else { return false }
                    toggleFavorite(result)
                case "r": speak(result)
                default: openInMainWindow(result)
                }
                return true
            default:
                return false
            }
        }
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76, case .error(let error) = state.content,
           let action = ErrorPresentation.make(error, shortcut: state.shortcut, serviceLine: state.serviceLine).action {
            perform(action)
            return true
        }
        return false
    }

    private func copy(_ text: String) {
        Pasteboard.copy(text)
        state.copied = true
    }

    private func speak(_ result: TranslationResult) {
        model.speech.speak(result.word?.headword ?? result.sourceText, language: result.sourceLanguage)
    }

    private func toggleFavorite(_ result: TranslationResult) {
        state.isFavorite = model.toggleFavorite(result)
    }

    private func togglePin() {
        state.isPinned.toggle()
        panel?.isMovableByWindowBackground = state.isPinned
    }

    private func openInMainWindow(_ result: TranslationResult) {
        close()
        model.openInMainWindow(result)
    }

    private func perform(_ action: ErrorPresentation.Action) {
        switch action {
        case .retry:
            model.retry()
        case .openSettings:
            close()
            WindowRouter.shared.showSettings(.service)
        case .openAccessibility:
            close()
            SystemSelectionEnvironment.requestAccessibilityPrompt()
            SystemSelectionEnvironment.openAccessibilitySettings()
        }
    }

    private func makeActions() -> PopupActions {
        PopupActions(
            copy: { [weak self] in self?.copy($0) },
            speak: { [weak self] in self?.speak($0) },
            toggleFavorite: { [weak self] in self?.toggleFavorite($0) },
            retarget: { [weak self] in self?.model.retargetPopup($0) },
            togglePin: { [weak self] in self?.togglePin() },
            openInMainWindow: { [weak self] in self?.openInMainWindow($0) },
            perform: { [weak self] in self?.perform($0) },
            close: { [weak self] in self?.close() }
        )
    }
}
