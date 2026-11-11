import Foundation

/// Every item and data type on the pasteboard, in order.
public struct PasteboardSnapshot: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var type: String
        public var data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public var items: [[Entry]]

    public init(items: [[Entry]]) {
        self.items = items
    }
}

public protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    /// Returns nil when some item or type cannot be read back, i.e. the contents
    /// could not be restored faithfully.
    func snapshot() -> PasteboardSnapshot?
    @discardableResult func restore(_ snapshot: PasteboardSnapshot) -> Bool
    func readString() -> String?
}

public enum AccessibilityReadResult: Equatable, Sendable {
    case text(String)
    /// The focused element confirms that the selection is empty.
    case empty
    /// Accessibility could not answer (unsupported element, timeout).
    case unavailable
}

/// System calls used while capturing a selection; mocked in tests.
@MainActor
public protocol SelectionEnvironment: AnyObject {
    func isAccessibilityTrusted() -> Bool
    func frontmostProcessID() -> pid_t?
    func readSelectedText(pid: pid_t) -> AccessibilityReadResult
    /// Waits briefly for the user to release the hotkey's modifier keys.
    func waitForModifierRelease() async -> Bool
    /// Posts Command-C to the frontmost app. Returns false when the event could not be created.
    func sendCopyCommand() -> Bool
    func sleep(milliseconds: Int) async
}

public enum CaptureMethod: Equatable, Sendable {
    case accessibility
    case copy
}

public enum CaptureFailure: Error, Equatable, Sendable {
    case permissionDenied
    case noFrontmostApp
    /// The frontmost app changed before or during copying.
    case frontmostAppChanged
    /// The clipboard holds data that could not be saved for restoring.
    case clipboardUnsavable
    /// Clipboard versions changed in a way that cannot be attributed to this copy.
    case clipboardChanged
    case clipboardRestoreFailed
    case modifiersHeld
    /// Copying did not change the clipboard: nothing selected, or the app ignores copy.
    case copyTimedOut
    /// Copying produced no usable text (e.g. only an image was selected).
    case noText
    case cancelled

    public var userMessage: String {
        switch self {
        case .permissionDenied:
            return "需要开启辅助功能权限才能读取其他应用中选中的文字。"
        case .noFrontmostApp:
            return "无法确定当前应用，请切换到目标应用后重试。"
        case .frontmostAppChanged:
            return "取词期间切换了应用，已停止本次取词。"
        case .clipboardUnsavable:
            return "当前剪贴板内容无法安全保存，已停止自动复制取词，以免丢失剪贴板内容。"
        case .clipboardChanged:
            return "取词期间剪贴板发生了其他变化，已保留最新内容。请重新选中文字后重试。"
        case .clipboardRestoreFailed:
            return "读取到文字，但恢复剪贴板失败。请检查剪贴板内容后重试。"
        case .modifiersHeld:
            return "请松开快捷键的修饰键后重试。"
        case .copyTimedOut:
            return "没有读取到选中的文字。请先选中文字再按快捷键；部分应用不支持取词。"
        case .noText:
            return "选中的内容里没有可翻译的文字，请重新选中。"
        case .cancelled:
            return "已取消。"
        }
    }
}

public enum CaptureOutcome: Equatable, Sendable {
    case success(text: String, method: CaptureMethod)
    case failure(CaptureFailure)
}

/// Reads the current selection in another app: accessibility first, then a
/// simulated Command-C that leaves the user's clipboard as it was.
@MainActor
public final class SelectionCapturer {
    private let environment: SelectionEnvironment
    private let pasteboard: PasteboardAccess
    private let copyTimeoutMilliseconds: Int
    private let pollMilliseconds: Int
    private var pendingCopy: (id: UUID, task: Task<CaptureOutcome, Never>)?

    public init(environment: SelectionEnvironment, pasteboard: PasteboardAccess,
                copyTimeoutMilliseconds: Int = 800, pollMilliseconds: Int = 20) {
        self.environment = environment
        self.pasteboard = pasteboard
        self.copyTimeoutMilliseconds = copyTimeoutMilliseconds
        self.pollMilliseconds = pollMilliseconds
    }

    /// - Parameter expectedPID: frontmost app recorded when the hotkey fired.
    public func capture(expectedPID: pid_t?) async -> CaptureOutcome {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        // A later capture must not snapshot another capture's temporary clipboard.
        while let pendingCopy {
            _ = await pendingCopy.task.value
            guard !Task.isCancelled else { return .failure(.cancelled) }
        }
        guard environment.isAccessibilityTrusted() else { return .failure(.permissionDenied) }
        guard let pid = expectedPID ?? environment.frontmostProcessID() else { return .failure(.noFrontmostApp) }
        guard environment.frontmostProcessID() == pid else { return .failure(.frontmostAppChanged) }

        switch environment.readSelectedText(pid: pid) {
        case .text(let text):
            return Self.hasContent(text) ? .success(text: text, method: .accessibility) : .failure(.noText)
        case .empty:
            return .failure(.noText)
        case .unavailable:
            break
        }

        let id = UUID()
        let cancellation = CaptureCancellation()
        // This task owns cleanup after Command-C, even if the caller stops waiting.
        let task = Task { [self] in
            defer { if pendingCopy?.id == id { pendingCopy = nil } }
            return await captureByCopying(pid: pid, cancellation: cancellation)
        }
        pendingCopy = (id, task)
        return await withTaskCancellationHandler {
            let result = await task.value
            return Task.isCancelled ? .failure(.cancelled) : result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func captureByCopying(pid: pid_t, cancellation: CaptureCancellation) async -> CaptureOutcome {
        let released = await environment.waitForModifierRelease()
        guard !cancellation.isCancelled else { return .failure(.cancelled) }
        guard released else { return .failure(.modifiersHeld) }

        let countBefore = pasteboard.changeCount
        guard let snapshot = pasteboard.snapshot() else { return .failure(.clipboardUnsavable) }
        guard pasteboard.changeCount == countBefore else { return .failure(.clipboardChanged) }
        guard environment.frontmostProcessID() == pid else { return .failure(.frontmostAppChanged) }
        guard !cancellation.isCancelled else { return .failure(.cancelled) }
        guard environment.sendCopyCommand() else { return .failure(.copyTimedOut) }

        var waited = 0
        var copiedCount: Int?
        var text: String?
        var appChanged = false
        while waited < copyTimeoutMilliseconds {
            await environment.sleep(milliseconds: pollMilliseconds)
            waited += pollMilliseconds
            appChanged = appChanged || environment.frontmostProcessID() != pid

            let count = pasteboard.changeCount
            if let copiedCount {
                guard count == copiedCount else { return .failure(.clipboardChanged) }
            } else if count != countBefore {
                // shortcut: versions cannot prove the writer, use source attribution if macOS exposes it.
                guard count == countBefore + 1 else { return .failure(.clipboardChanged) }
                copiedCount = count
            }
            if copiedCount != nil { text = pasteboard.readString() }
            // Some apps clear the pasteboard before they write the copied text.
            if text != nil { break }
        }

        guard let copiedCount else {
            if cancellation.isCancelled { return .failure(.cancelled) }
            return .failure(appChanged ? .frontmostAppChanged : .copyTimedOut)
        }
        if pasteboard.changeCount == copiedCount, !pasteboard.restore(snapshot) {
            return .failure(.clipboardRestoreFailed)
        }
        if cancellation.isCancelled { return .failure(.cancelled) }
        if appChanged { return .failure(.frontmostAppChanged) }
        guard let text, Self.hasContent(text) else { return .failure(.noText) }
        return .success(text: text, method: .copy)
    }

    static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
