import Foundation

public enum FlowError: Error, Equatable, Sendable {
    case capture(CaptureFailure)
    /// Captured text has nothing translatable.
    case invalidSelection
    case translation(TranslationError)

    public var userMessage: String {
        switch self {
        case .capture(let failure): return failure.userMessage
        case .invalidSelection: return "选中的内容里没有可翻译的文字，请重新选中。"
        case .translation(let error): return error.userMessage
        }
    }
}

@MainActor
public protocol TranslationPresenter: AnyObject {
    func showLoading(requestID: UUID, sourceText: String)
    func show(result: TranslationResult, requestID: UUID)
    func show(error: FlowError, requestID: UUID)
}

/// Stored translations checked before calling the model.
public protocol TranslationCache: AnyObject {
    func cachedResult(for request: TranslationRequest) throws -> TranslationResult?
    func cache(_ result: TranslationResult, for request: TranslationRequest, at date: Date) throws
}

/// One hotkey press: capture → analyze → translate → present. The newest
/// request always wins; older results are dropped instead of overwriting it.
@MainActor
public final class TranslationFlow {
    public typealias Capture = (pid_t?) async -> CaptureOutcome

    public enum State: Equatable, Sendable {
        case idle
        case capturing(UUID)
        case translating(UUID)
        case succeeded(UUID)
        case failed(UUID, FlowError)

        public var requestID: UUID? {
            switch self {
            case .idle: return nil
            case .capturing(let id), .translating(let id), .succeeded(let id), .failed(let id, _): return id
            }
        }
    }

    private let capture: Capture
    private let rules: () -> LanguageRules
    private let makeTranslator: () throws -> Translator
    private let cache: TranslationCache?
    private let onSuccess: (TranslationResult) -> Void
    public weak var presenter: TranslationPresenter?

    public private(set) var state: State = .idle
    public var currentRequestID: UUID? { state.requestID }
    private var task: Task<Void, Never>?
    private var lastAttempt: (analysis: TextAnalysis, useCache: Bool)?

    public init(capture: @escaping Capture,
                rules: @escaping () -> LanguageRules,
                makeTranslator: @escaping () throws -> Translator,
                cache: TranslationCache? = nil,
                onSuccess: @escaping (TranslationResult) -> Void) {
        self.capture = capture
        self.rules = rules
        self.makeTranslator = makeTranslator
        self.cache = cache
        self.onSuccess = onSuccess
    }

    /// Starts a new request from the current selection, replacing any running one.
    @discardableResult
    public func trigger(frontmostPID: pid_t?) -> UUID {
        cancel()
        lastAttempt = nil
        let id = UUID()
        state = .capturing(id)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.currentRequestID == id { self.task = nil } }
            let outcome = await self.capture(frontmostPID)
            guard self.isCurrent(id) else { return }
            switch outcome {
            case .failure(.cancelled):
                self.cancel()
            case .failure(let failure):
                self.state = .failed(id, .capture(failure))
                self.presenter?.show(error: .capture(failure), requestID: id)
            case .success(let text, _):
                guard let analysis = TextAnalyzer.analyze(text, rules: self.rules()) else {
                    self.state = .failed(id, .invalidSelection)
                    self.presenter?.show(error: .invalidSelection, requestID: id)
                    return
                }
                await self.translate(analysis, id: id)
            }
        }
        return id
    }

    /// Starts a new request from typed text, skipping selection capture.
    /// `targetLanguage` overrides the language rules for this request;
    /// `useCache: false` asks the model again and refreshes the cached result.
    @discardableResult
    public func translate(text: String, targetLanguage: String? = nil, useCache: Bool = true) -> UUID {
        guard var analysis = TextAnalyzer.analyze(text, rules: rules()) else {
            cancel()
            lastAttempt = nil
            let id = UUID()
            state = .failed(id, .invalidSelection)
            presenter?.show(error: .invalidSelection, requestID: id)
            return id
        }
        if let targetLanguage { analysis.targetLanguage = targetLanguage }
        return startTranslation(analysis, useCache: useCache)
    }

    /// Translates the latest analyzed input again, preserving its cache policy.
    @discardableResult
    public func retry() -> UUID? {
        guard let lastAttempt else { return nil }
        return startTranslation(lastAttempt.analysis, useCache: lastAttempt.useCache)
    }

    /// Translates the last text into another language, for this request only.
    @discardableResult
    public func retarget(_ targetLanguage: String) -> UUID? {
        guard var analysis = lastAttempt?.analysis else { return nil }
        analysis.targetLanguage = targetLanguage
        return startTranslation(analysis)
    }

    /// Called when the result window closes: stops waiting for the current request.
    public func cancel() {
        state = .idle
        task?.cancel()
        task = nil
    }

    private func startTranslation(_ analysis: TextAnalysis, useCache: Bool = true) -> UUID {
        cancel()
        let id = UUID()
        state = .translating(id)
        // Capture retry input before the task can be replaced by another request.
        lastAttempt = (analysis, useCache)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.currentRequestID == id { self.task = nil } }
            await self.translate(analysis, id: id, useCache: useCache)
        }
        return id
    }

    private func isCurrent(_ id: UUID) -> Bool {
        currentRequestID == id && !Task.isCancelled
    }

    private func translate(_ analysis: TextAnalysis, id: UUID, useCache: Bool = true) async {
        guard isCurrent(id) else { return }
        lastAttempt = (analysis, useCache)
        state = .translating(id)
        presenter?.showLoading(requestID: id, sourceText: analysis.text)
        guard isCurrent(id) else { return }
        let request = TranslationRequest(
            id: id,
            text: analysis.text,
            kind: analysis.kind,
            sourceLanguage: analysis.sourceLanguage,
            targetLanguage: LanguageOption.named(analysis.targetLanguage)
        )
        // Cache failures fall through to the model; they never block a lookup.
        if useCache, let cached = try? cache?.cachedResult(for: request) {
            state = .succeeded(id)
            onSuccess(cached)
            guard isCurrent(id) else { return }
            presenter?.show(result: cached, requestID: id)
            return
        }
        do {
            let result = try await makeTranslator().translate(request)
            guard isCurrent(id) else { return }
            try? cache?.cache(result, for: request, at: Date())
            state = .succeeded(id)
            onSuccess(result)
            guard isCurrent(id) else { return }
            presenter?.show(result: result, requestID: id)
        } catch {
            guard isCurrent(id) else { return }
            let translationError: TranslationError = error is CancellationError
                ? .cancelled : (error as? TranslationError) ?? .network(error.localizedDescription)
            state = .failed(id, .translation(translationError))
            presenter?.show(error: .translation(translationError), requestID: id)
        }
    }
}
