import AppKit
import AVFoundation
import HuaciCore
import Testing
@testable import Huaci

@Suite(.serialized)
@MainActor
struct NativeLifecycleTests {
    @Test func installedEventHandlerConsumesOnlyItsOwningWindow() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let session = ShortcutRecordingSession()
        var suspends = 0
        var restores = 0
        var received: [UInt16] = []
        var installed: ShortcutRecordingSession.EventHandler?
        session.start(window: owner, suspend: { suspends += 1 }, restore: { restores += 1 }, installMonitor: { handler in
            installed = handler
            return NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        }, receive: { received.append($0.keyCode) })
        defer { session.stop(); owner.close(); other.close() }
        #expect(session.isRecording)

        for window in [owner, other] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: "a",
                                                     charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            let handler = try #require(installed)
            let forwarded = handler(event)
            if window === owner { #expect(forwarded == nil) }
            else { #expect(forwarded === event) }
        }
        #expect(received == [0])
        #expect(!session.isRecording)
        #expect(suspends == 1)
        #expect(restores == 1)
    }

    @Test func oldSpeechCallbacksCannotStopAReplacementUtterance() async throws {
        final class SilentSynthesizer: AVSpeechSynthesizer {
            var spoken: [AVSpeechUtterance] = []
            override func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance) }
            override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
        }
        let synthesizer = SilentSynthesizer()
        let speech = Speech(synthesizer: synthesizer)
        let first = TranslationResult(kind: .text, sourceText: "first", sourceLanguage: nil, targetLanguage: "zh-Hans", translation: "一", word: nil)
        let second = TranslationResult(kind: .text, sourceText: "second", sourceLanguage: nil, targetLanguage: "zh-Hans", translation: "二", word: nil)
        speech.toggle(first)
        speech.toggle(second)
        #expect(synthesizer.spoken.count == 2)
        let old = try #require(synthesizer.spoken.first)
        let current = try #require(synthesizer.spoken.last)

        speech.speechSynthesizer(synthesizer, didCancel: old)
        speech.speechSynthesizer(synthesizer, didFinish: old)
        for _ in 0..<20 { await Task.yield() }
        #expect(speech.isSpeaking(second))
        #expect(!speech.isSpeaking(first))

        speech.speechSynthesizer(synthesizer, didFinish: current)
        for _ in 0..<20 { await Task.yield() }
        #expect(!speech.isSpeaking(second))
    }

    @Test func recordingBelongsOnlyToItsWindow() {
        let session = ShortcutRecordingSession()
        let owner = NSObject()
        let other = NSObject()
        var restores = 0
        session.begin(owner: owner) { if $0 { restores += 1 } }
        #expect(session.owns(owner))
        #expect(!session.owns(other))
        #expect(!session.owns(nil))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(session.isRecording)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner)
        #expect(!session.isRecording)
        #expect(!session.owns(owner))
        session.stop()
        #expect(restores == 1)
    }

    @Test func deactivationRestoresExactlyOnce() {
        let session = ShortcutRecordingSession()
        let owner = NSObject()
        var restores = 0
        session.begin(owner: owner) { if $0 { restores += 1 } }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        session.stop()
        #expect(!session.isRecording)
        #expect(restores == 1)
    }

    @Test func replacementRecorderExclusivelyOwnsRestoration() {
        let first = ShortcutRecordingSession()
        let second = ShortcutRecordingSession()
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        var firstRestores = 0
        var secondRestores = 0
        first.begin(owner: firstOwner) { if $0 { firstRestores += 1 } }
        second.begin(owner: secondOwner) { if $0 { secondRestores += 1 } }
        #expect(!first.isRecording)
        #expect(second.isRecording)
        #expect(firstRestores == 1)
        first.stop()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: firstOwner)
        #expect(second.isRecording)
        #expect(secondRestores == 0)
        second.stop()
        #expect(secondRestores == 1)
    }

    @Test func acceptingShortcutDoesNotRestoreSuspendedShortcut() {
        let session = ShortcutRecordingSession()
        let owner = NSObject()
        var stopped: [Bool] = []
        session.begin(owner: owner) { stopped.append($0) }
        session.stop(restore: false)
        session.stop()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(stopped == [false])
    }

    @Test func rollbackFailureNeverClaimsShortcutRestored() {
        let previous = Shortcut.defaultShortcut
        let replacement = Shortcut(keyCode: 0, modifiers: .command)
        var calls: [Shortcut] = []
        let message = ShortcutRecorder.apply(replacement, previous: previous) { shortcut in
            calls.append(shortcut)
            return calls.count == 1 ? .registrationFailed(-1) : .handlerInstallationFailed(-2)
        }
        #expect(calls == [replacement, previous])
        #expect(message?.contains("未能恢复") == true)
        #expect(message?.contains("已恢复") == false)
        #expect(message?.contains("-2") == true)
    }

    @Test func successfulRollbackReportsOriginalShortcut() {
        let previous = Shortcut.defaultShortcut
        let replacement = Shortcut(keyCode: 0, modifiers: .command)
        var calls = 0
        let message = ShortcutRecorder.apply(replacement, previous: previous) { _ in
            calls += 1
            return calls == 1 ? .takenBySystem : nil
        }
        #expect(calls == 2)
        #expect(message?.contains("已恢复原快捷键 \(previous.displayString)") == true)
    }

    @Test func successfulShortcutDoesNotAttemptRollback() {
        var calls = 0
        let message = ShortcutRecorder.apply(.defaultShortcut, previous: .defaultShortcut) { _ in
            calls += 1
            return nil
        }
        #expect(message == nil)
        #expect(calls == 1)
    }

    @Test func hintsAllowReadingAndDoNotExpireForVoiceOver() {
        #expect(PopupController.hintDuration(text: "没有选中文字", voiceOver: false) == 4)
        #expect(PopupController.hintDuration(text: String(repeating: "字", count: 48), voiceOver: false) == 8)
        #expect(PopupController.hintDuration(text: String(repeating: "字", count: 200), voiceOver: false) == 12)
        #expect(PopupController.hintDuration(text: "没有选中文字", voiceOver: true) == nil)
    }
}
