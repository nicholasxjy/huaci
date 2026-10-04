import Foundation
import Testing
@testable import HuaciCore

/// In-memory pasteboard with NSPasteboard-like change counting.
final class FakePasteboard: PasteboardAccess {
    private(set) var contents: PasteboardSnapshot
    private(set) var changeCount = 100
    var unsavable = false
    private(set) var snapshotCalls = 0
    private(set) var restoreCalls = 0
    /// Runs after each read, e.g. to simulate the user copying something.
    var afterRead: (() -> Void)?

    init(_ contents: PasteboardSnapshot) {
        self.contents = contents
    }

    func write(_ contents: PasteboardSnapshot) {
        changeCount += 1
        self.contents = contents
    }

    func clear() {
        changeCount += 1
        contents = PasteboardSnapshot(items: [])
    }

    func snapshot() -> PasteboardSnapshot? {
        snapshotCalls += 1
        return unsavable ? nil : contents
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        restoreCalls += 1
        write(snapshot)
    }

    func readString() -> String? {
        defer { afterRead?() }
        return contents.items.first?.first(where: { $0.type == "public.utf8-plain-text" }).map { String(decoding: $0.data, as: UTF8.self) }
    }

    static func text(_ value: String) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [[.init(type: "public.utf8-plain-text", data: Data(value.utf8))]])
    }
}

@MainActor
final class FakeEnvironment: SelectionEnvironment {
    var trusted = true
    var frontmost: pid_t? = 42
    var accessibility: AccessibilityReadResult = .unavailable
    /// What the target app does when it receives Command-C.
    var onCopy: (() -> Void)?
    /// Runs on each poll, e.g. to switch apps mid-copy.
    var onSleep: (() -> Void)?
    private(set) var copyCount = 0

    func isAccessibilityTrusted() -> Bool { trusted }
    func frontmostProcessID() -> pid_t? { frontmost }
    func readSelectedText(pid: pid_t) -> AccessibilityReadResult { accessibility }
    func waitForModifierRelease() async {}
    func sendCopyCommand() -> Bool {
        copyCount += 1
        onCopy?()
        return true
    }
    func sleep(milliseconds: Int) async { onSleep?() }
}

@MainActor
struct SelectionCaptureTests {
    /// Image plus rich text across two items, to check multi-item, multi-type restore.
    let original = PasteboardSnapshot(items: [
        [.init(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
         .init(type: "public.tiff", data: Data([0x4D, 0x4D]))],
        [.init(type: "public.utf8-plain-text", data: Data("old clipboard".utf8)),
         .init(type: "public.rtf", data: Data("{\\rtf1 old}".utf8))],
    ])

    func makeCapturer(_ environment: FakeEnvironment, _ pasteboard: FakePasteboard) -> SelectionCapturer {
        SelectionCapturer(environment: environment, pasteboard: pasteboard, copyTimeoutMilliseconds: 200, pollMilliseconds: 20)
    }

    @Test func accessibilityReadLeavesClipboardUntouched() async {
        let environment = FakeEnvironment()
        environment.accessibility = .text("selected via AX")
        let pasteboard = FakePasteboard(original)

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .success(text: "selected via AX", method: .accessibility))
        #expect(environment.copyCount == 0)
        #expect(pasteboard.snapshotCalls == 0)
        #expect(pasteboard.changeCount == 100)
    }

    @Test func copyFallbackRestoresAllItemsAndTypes() async {
        let environment = FakeEnvironment()
        environment.accessibility = .empty
        let pasteboard = FakePasteboard(original)
        environment.onCopy = { pasteboard.write(FakePasteboard.text("copied selection")) }

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .success(text: "copied selection", method: .copy))
        #expect(pasteboard.contents == original)
        #expect(pasteboard.restoreCalls == 1)
    }

    @Test func copyThatClearsBeforeWritingIsAwaited() async {
        let environment = FakeEnvironment()
        let pasteboard = FakePasteboard(original)
        var polls = 0
        environment.onCopy = { pasteboard.clear() }
        environment.onSleep = {
            polls += 1
            if polls == 3 { pasteboard.write(FakePasteboard.text("late text")) }
        }

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .success(text: "late text", method: .copy))
        #expect(pasteboard.contents == original)
    }

    @Test func unchangedClipboardIsNeverReadAsSelection() async {
        let environment = FakeEnvironment()
        let pasteboard = FakePasteboard(FakePasteboard.text("stale clipboard text"))

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .failure(.copyTimedOut))
        #expect(environment.copyCount == 1)
        #expect(pasteboard.restoreCalls == 0)
        #expect(pasteboard.changeCount == 100)
    }

    @Test func newerUserCopyIsKept() async {
        let environment = FakeEnvironment()
        let pasteboard = FakePasteboard(original)
        environment.onCopy = { pasteboard.write(FakePasteboard.text("copied selection")) }
        pasteboard.afterRead = {
            pasteboard.afterRead = nil
            pasteboard.write(FakePasteboard.text("user copied this"))
        }

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .success(text: "copied selection", method: .copy))
        #expect(pasteboard.restoreCalls == 0)
        #expect(pasteboard.contents == FakePasteboard.text("user copied this"))
    }

    @Test func unsavableClipboardStopsBeforeCopying() async {
        let environment = FakeEnvironment()
        let pasteboard = FakePasteboard(original)
        pasteboard.unsavable = true

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .failure(.clipboardUnsavable))
        #expect(environment.copyCount == 0)
        #expect(pasteboard.contents == original)
    }

    @Test func appSwitchBeforeCopySendsNothing() async {
        let environment = FakeEnvironment()
        environment.frontmost = 7
        let pasteboard = FakePasteboard(original)

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .failure(.frontmostAppChanged))
        #expect(environment.copyCount == 0)
    }

    @Test func appSwitchDuringCopyAbortsAndRestores() async {
        let environment = FakeEnvironment()
        let pasteboard = FakePasteboard(original)
        environment.onCopy = { pasteboard.write(FakePasteboard.text("copied selection")) }
        environment.onSleep = { environment.frontmost = 7 }

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .failure(.frontmostAppChanged))
        #expect(pasteboard.contents == original)
    }

    @Test func copiedImageWithoutTextIsRejectedAndRestored() async {
        let environment = FakeEnvironment()
        let pasteboard = FakePasteboard(FakePasteboard.text("previous"))
        environment.onCopy = { pasteboard.write(PasteboardSnapshot(items: [[.init(type: "public.png", data: Data([1, 2, 3]))]])) }

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .failure(.noText))
        #expect(pasteboard.contents == FakePasteboard.text("previous"))
    }

    @Test func emptyClipboardIsRestoredAsEmpty() async {
        let environment = FakeEnvironment()
        let pasteboard = FakePasteboard(PasteboardSnapshot(items: []))
        environment.onCopy = { pasteboard.write(FakePasteboard.text("copied")) }

        let outcome = await makeCapturer(environment, pasteboard).capture(expectedPID: 42)

        #expect(outcome == .success(text: "copied", method: .copy))
        #expect(pasteboard.contents.items.isEmpty)
    }

    @Test func whitespaceSelectionIsRejected() async {
        let environment = FakeEnvironment()
        environment.accessibility = .text("   \n")
        let pasteboard = FakePasteboard(original)
        environment.onCopy = { pasteboard.write(FakePasteboard.text("  ")) }

        #expect(await makeCapturer(environment, pasteboard).capture(expectedPID: 42) == .failure(.noText))
        #expect(pasteboard.contents == original)
    }

    @Test func missingPermissionIsReported() async {
        let environment = FakeEnvironment()
        environment.trusted = false
        let pasteboard = FakePasteboard(original)

        #expect(await makeCapturer(environment, pasteboard).capture(expectedPID: 42) == .failure(.permissionDenied))
        #expect(environment.copyCount == 0)
    }
}
