import Foundation
import Testing
@testable import HuaciCore

@MainActor
final class RecordingPresenter: TranslationPresenter {
    enum Event: Equatable {
        case loading(UUID, String)
        case result(UUID, String)
        case error(UUID, FlowError)
    }

    private(set) var events: [Event] = []

    func showLoading(requestID: UUID, sourceText: String) { events.append(.loading(requestID, sourceText)) }
    func show(result: TranslationResult, requestID: UUID) { events.append(.result(requestID, result.translation)) }
    func show(error: FlowError, requestID: UUID) { events.append(.error(requestID, error)) }

    var results: [Event] { events.filter { if case .result = $0 { true } else { false } } }
}

/// Translator whose replies are released by the test; ignores task cancellation
/// like a request already in flight would.
final class ControlledTranslator: Translator, @unchecked Sendable {
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private let lock = NSLock()
    var failure: TranslationError?

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released.contains(request.text) {
                lock.unlock()
                continuation.resume()
            } else {
                pending[request.text] = continuation
                lock.unlock()
            }
        }
        if let failure { throw failure }
        return TranslationResult(kind: .text, sourceText: request.text, sourceLanguage: request.sourceLanguage,
                                 targetLanguage: request.targetLanguage.code, translation: "译:\(request.text)", word: nil)
    }

    func release(_ text: String) {
        lock.lock()
        released.insert(text)
        let continuation = pending.removeValue(forKey: text)
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
struct TranslationFlowTests {
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func makeFlow(captures: [CaptureOutcome], translator: Translator, cache: TranslationCache? = nil,
                  saved: @escaping (TranslationResult) -> Void = { _ in })
        -> (TranslationFlow, RecordingPresenter) {
        makeFlow(captures: captures, makeTranslator: { translator }, cache: cache, saved: saved)
    }

    func makeFlow(captures: [CaptureOutcome], makeTranslator: @escaping () throws -> Translator, cache: TranslationCache? = nil,
                  saved: @escaping (TranslationResult) -> Void = { _ in })
        -> (TranslationFlow, RecordingPresenter) {
        var queue = captures
        let flow = TranslationFlow(
            capture: { _ in queue.removeFirst() },
            rules: { LanguageRules() },
            makeTranslator: makeTranslator,
            cache: cache,
            onSuccess: saved
        )
        let presenter = RecordingPresenter()
        flow.presenter = presenter
        return (flow, presenter)
    }

    @Test func newestRequestWinsOverSlowerOlderOne() async {
        let translator = ControlledTranslator()
        var saved: [String] = []
        let (flow, presenter) = makeFlow(
            captures: [.success(text: "First sentence here.", method: .accessibility),
                       .success(text: "Second sentence here.", method: .copy)],
            translator: translator,
            saved: { saved.append($0.sourceText) }
        )

        let first = flow.trigger(frontmostPID: 1)
        await settle()
        let second = flow.trigger(frontmostPID: 1)
        await settle()
        translator.release("Second sentence here.")
        await settle()
        translator.release("First sentence here.")
        await settle()

        #expect(presenter.results == [.result(second, "译:Second sentence here.")])
        #expect(!presenter.events.contains { if case .result(first, _) = $0 { true } else { false } })
        #expect(saved == ["Second sentence here."])
    }

    @Test func closingCancelsPendingResult() async {
        let translator = ControlledTranslator()
        var saved = 0
        let (flow, presenter) = makeFlow(captures: [.success(text: "hello", method: .accessibility)],
                                         translator: translator, saved: { _ in saved += 1 })

        let id = flow.trigger(frontmostPID: 1)
        await settle()
        flow.cancel()
        translator.release("hello")
        await settle()

        #expect(presenter.events == [.loading(id, "hello")])
        #expect(saved == 0)
        #expect(flow.currentRequestID == nil)
    }

    @Test func captureFailureIsShownWithoutTranslating() async {
        let translator = ControlledTranslator()
        let (flow, presenter) = makeFlow(captures: [.failure(.copyTimedOut)], translator: translator)

        let id = flow.trigger(frontmostPID: 1)
        await settle()

        #expect(presenter.events == [.error(id, .capture(.copyTimedOut))])
    }

    @Test func untranslatableSelectionIsRejected() async {
        let (flow, presenter) = makeFlow(captures: [.success(text: "1234 !!", method: .copy)], translator: ControlledTranslator())

        let id = flow.trigger(frontmostPID: 1)
        await settle()

        #expect(presenter.events == [.error(id, .invalidSelection)])
    }

    @Test func translationErrorIsShownAndRetryWorks() async {
        let translator = ControlledTranslator()
        translator.failure = .timeout
        translator.release("Some sentence, here.")
        var saved = 0
        let (flow, presenter) = makeFlow(captures: [.success(text: "Some sentence, here.", method: .copy)],
                                         translator: translator, saved: { _ in saved += 1 })

        let id = flow.trigger(frontmostPID: 1)
        await settle()
        #expect(presenter.events.last == .error(id, .translation(.timeout)))

        translator.failure = nil
        let retryID = flow.retry()
        await settle()
        #expect(retryID != nil && retryID != id)
        #expect(presenter.events.last == .result(retryID!, "译:Some sentence, here."))
        #expect(saved == 1)
    }

    @Test func requestIDIsSentToTranslator() async {
        final class Spy: Translator, @unchecked Sendable {
            var ids: [UUID] = []
            func translate(_ request: TranslationRequest) async throws -> TranslationResult {
                ids.append(request.id)
                return TranslationResult(kind: .word, sourceText: request.text, sourceLanguage: nil, targetLanguage: "zh-Hans", translation: "x", word: nil)
            }
        }
        let spy = Spy()
        let (flow, _) = makeFlow(captures: [.success(text: "word", method: .copy)], translator: spy)
        let id = flow.trigger(frontmostPID: 1)
        await settle()
        #expect(spy.ids == [id])
    }

    @Test func cacheHitIsShownAndSavedWithoutCallingModel() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let cached = TranslationRequest(text: "Some sentence, here.", kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        try store.cache(TranslationResult(kind: .text, sourceText: cached.text, sourceLanguage: "en", targetLanguage: "zh-Hans",
                                          translation: "缓存的译文", word: nil), for: cached)
        var saved: [String] = []
        // Not configured: a cache hit must not need a translator at all.
        let (flow, presenter) = makeFlow(captures: [.success(text: "Some sentence, here.", method: .copy)],
                                         makeTranslator: { throw TranslationError.notConfigured("x") },
                                         cache: store, saved: { saved.append($0.translation) })

        let id = flow.trigger(frontmostPID: 1)
        await settle()

        #expect(presenter.events == [.loading(id, "Some sentence, here."), .result(id, "缓存的译文")])
        #expect(saved == ["缓存的译文"])
    }

    @Test func cacheMissTranslatesThenServesNextLookupFromCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let translator = ControlledTranslator()
        translator.release("Some sentence, here.")
        var calls = 0
        let (flow, presenter) = makeFlow(captures: [.success(text: "Some sentence, here.", method: .copy),
                                                    .success(text: "Some sentence, here.", method: .copy)],
                                         makeTranslator: { calls += 1; return translator }, cache: store)

        let first = flow.trigger(frontmostPID: 1)
        await settle()
        let second = flow.trigger(frontmostPID: 1)
        await settle()

        #expect(presenter.results == [.result(first, "译:Some sentence, here."), .result(second, "译:Some sentence, here.")])
        #expect(calls == 1)
    }

    @Test func failedTranslationIsNotCached() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let translator = ControlledTranslator()
        translator.failure = .timeout
        translator.release("Some sentence, here.")
        let (flow, presenter) = makeFlow(captures: [.success(text: "Some sentence, here.", method: .copy)],
                                         translator: translator, cache: store)

        let id = flow.trigger(frontmostPID: 1)
        await settle()

        #expect(presenter.events.last == .error(id, .translation(.timeout)))
        let request = TranslationRequest(text: "Some sentence, here.", kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        #expect(try store.cachedResult(for: request) == nil)
    }
}
