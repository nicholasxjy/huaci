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
    func restore(_ snapshot: PasteboardSnapshot)
    func readString() -> String?
}

public enum AccessibilityReadResult: Equatable, Sendable {
    case text(String)
    /// The focused element reports an empty selection or no selection attribute.
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
    func waitForModifierRelease() async
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

    public init(environment: SelectionEnvironment, pasteboard: PasteboardAccess,
                copyTimeoutMilliseconds: Int = 800, pollMilliseconds: Int = 20) {
        self.environment = environment
        self.pasteboard = pasteboard
        self.copyTimeoutMilliseconds = copyTimeoutMilliseconds
        self.pollMilliseconds = pollMilliseconds
    }

    /// - Parameter expectedPID: frontmost app recorded when the hotkey fired.
    public func capture(expectedPID: pid_t?) async -> CaptureOutcome {
        guard environment.isAccessibilityTrusted() else { return .failure(.permissionDenied) }
        guard let pid = expectedPID ?? environment.frontmostProcessID() else { return .failure(.noFrontmostApp) }
        guard environment.frontmostProcessID() == pid else { return .failure(.frontmostAppChanged) }

        if case .text(let text) = environment.readSelectedText(pid: pid), Self.hasContent(text) {
            return .success(text: text, method: .accessibility)
        }
        return await captureByCopying(pid: pid)
    }

    private func captureByCopying(pid: pid_t) async -> CaptureOutcome {
        await environment.waitForModifierRelease()
        if Task.isCancelled { return .failure(.cancelled) }

        guard let snapshot = pasteboard.snapshot() else { return .failure(.clipboardUnsavable) }
        let countBefore = pasteboard.changeCount
        // Re-check right before posting so Command-C never reaches another app.
        guard environment.frontmostProcessID() == pid else { return .failure(.frontmostAppChanged) }
        guard environment.sendCopyCommand() else { return .failure(.copyTimedOut) }

        var waited = 0
        var copiedCount: Int?
        var text: String?
        while waited < copyTimeoutMilliseconds {
            await environment.sleep(milliseconds: pollMilliseconds)
            waited += pollMilliseconds

            let count = pasteboard.changeCount
            if count != countBefore {
                copiedCount = count
                text = pasteboard.readString()
            }
            guard environment.frontmostProcessID() == pid else {
                if let copiedCount { restoreIfUnchanged(snapshot, expectedCount: copiedCount, countBefore: countBefore) }
                return .failure(.frontmostAppChanged)
            }
            // Apps may clear the pasteboard before writing; keep polling until text arrives.
            if text != nil { break }
        }

        guard let copiedCount else { return .failure(.copyTimedOut) }
        restoreIfUnchanged(snapshot, expectedCount: copiedCount, countBefore: countBefore)
        if Task.isCancelled { return .failure(.cancelled) }
        guard let text, Self.hasContent(text) else { return .failure(.noText) }
        return .success(text: text, method: .copy)
    }

    /// Restores only while the clipboard still holds our copy; anything the user
    /// copied in the meantime is kept.
    private func restoreIfUnchanged(_ snapshot: PasteboardSnapshot, expectedCount: Int, countBefore: Int) {
        let count = pasteboard.changeCount
        guard count != countBefore, count == expectedCount else { return }
        pasteboard.restore(snapshot)
    }

    static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
