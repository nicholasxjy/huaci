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

    private let capture: Capture
    private let rules: () -> LanguageRules
    private let makeTranslator: () throws -> Translator
    private let cache: TranslationCache?
    private let onSuccess: (TranslationResult) -> Void
    public weak var presenter: TranslationPresenter?

    public private(set) var currentRequestID: UUID?
    private var task: Task<Void, Never>?
    private var lastAnalysis: TextAnalysis?

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
        let id = start()
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.capture(frontmostPID)
            guard self.isCurrent(id) else { return }
            switch outcome {
            case .failure(.cancelled):
                return
            case .failure(let failure):
                self.presenter?.show(error: .capture(failure), requestID: id)
            case .success(let text, _):
                guard let analysis = TextAnalyzer.analyze(text, rules: self.rules()) else {
                    self.presenter?.show(error: .invalidSelection, requestID: id)
                    return
                }
                await self.translate(analysis, id: id)
            }
        }
        return id
    }

    /// Translates the last captured text again, e.g. after an error.
    @discardableResult
    public func retry() -> UUID? {
        guard let analysis = lastAnalysis else { return nil }
        let id = start()
        task = Task { [weak self] in await self?.translate(analysis, id: id) }
        return id
    }

    /// Called when the result window closes: stops waiting for the current request.
    public func cancel() {
        currentRequestID = nil
        task?.cancel()
        task = nil
    }

    private func start() -> UUID {
        task?.cancel()
        let id = UUID()
        currentRequestID = id
        return id
    }

    private func isCurrent(_ id: UUID) -> Bool {
        currentRequestID == id && !Task.isCancelled
    }

    private func translate(_ analysis: TextAnalysis, id: UUID) async {
        lastAnalysis = analysis
        presenter?.showLoading(requestID: id, sourceText: analysis.text)
        let request = TranslationRequest(
            id: id,
            text: analysis.text,
            kind: analysis.kind,
            sourceLanguage: analysis.sourceLanguage,
            targetLanguage: LanguageOption.named(analysis.targetLanguage)
        )
        // Cache failures fall through to the model; they never block a lookup.
        if let cached = try? cache?.cachedResult(for: request) {
            onSuccess(cached)
            presenter?.show(result: cached, requestID: id)
            return
        }
        do {
            let result = try await makeTranslator().translate(request)
            try? cache?.cache(result, for: request, at: Date())
            guard isCurrent(id) else { return }
            onSuccess(result)
            presenter?.show(result: result, requestID: id)
        } catch {
            guard isCurrent(id) else { return }
            let translationError = (error as? TranslationError) ?? .network(error.localizedDescription)
            if translationError == .cancelled { return }
            presenter?.show(error: .translation(translationError), requestID: id)
        }
    }
}
