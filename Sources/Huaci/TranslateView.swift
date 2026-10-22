import AppKit
import HuaciCore
import SwiftUI

/// State of the main window's translate tab; presents its own flow's results.
@MainActor
final class InputTranslationState: ObservableObject, TranslationPresenter {
    enum Content {
        case idle
        case loading(String)
        case result(TranslationResult)
        case error(FlowError)
    }

    @Published var text = ""
    @Published var content: Content = .idle
    @Published var isFavorite = false
    @Published var copied = false
    /// Target chosen in the tab; nil follows the language settings.
    @Published var targetOverride: String?

    /// Set by the model, which owns favorites.
    var isFavoriteResult: (TranslationResult) -> Bool = { _ in false }

    var result: TranslationResult? {
        if case .result(let result) = content { return result }
        return nil
    }

    func showLoading(requestID: UUID, sourceText: String) {
        content = .loading(sourceText)
    }

    func show(result: TranslationResult, requestID: UUID) {
        copied = false
        isFavorite = isFavoriteResult(result)
        content = .result(result)
    }

    func show(error: FlowError, requestID: UUID) {
        content = .error(error)
    }
}

struct TranslateView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var state: InputTranslationState
    @FocusState private var editorFocused: Bool

    private var isEmpty: Bool { state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var analysis: TextAnalysis? { TextAnalyzer.analyze(state.text, rules: settings.languageRules) }
    private var target: String { state.targetOverride ?? analysis?.targetLanguage ?? settings.foreignTarget }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("翻译").font(.system(size: 15, weight: .semibold))
                Spacer()
                direction
            }
            .padding(.horizontal, 24)
            .frame(height: 52)

            HStack(spacing: 16) {
                inputCard
                resultCard
            }
            .padding([.horizontal, .bottom], 24)
        }
        .onAppear { editorFocused = true }
    }

    private var direction: some View {
        HStack(spacing: 8) {
            Text("自动识别").foregroundStyle(.secondary)
            if let analysis { Text(LanguageOption.chineseName(analysis.sourceLanguage)) }
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
            Menu {
                Button {
                    setTarget(nil)
                } label: {
                    if state.targetOverride == nil { Label("跟随语言设置", systemImage: "checkmark") } else { Text("跟随语言设置") }
                }
                Divider()
                ForEach(LanguageOption.all) { option in
                    Button {
                        setTarget(option.code)
                    } label: {
                        if state.targetOverride == option.code {
                            Label(LanguageOption.chineseName(option.code), systemImage: "checkmark")
                        } else {
                            Text(LanguageOption.chineseName(option.code))
                        }
                    }
                }
            } label: {
                Text(LanguageOption.chineseName(target))
            }
            .fixedSize()
            .help("目标语言")
        }
        .font(.system(size: 12))
    }

    private func setTarget(_ code: String?) {
        state.targetOverride = code
        if !isEmpty, state.result != nil { model.translateInput() }
    }

    // MARK: Input

    private var inputCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.text)
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14))
                    .accessibilityLabel("原文")
                if state.text.isEmpty {
                    Text("输入或粘贴要翻译的单词、句子")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                        .padding(EdgeInsets(top: 14, leading: 19, bottom: 0, trailing: 19))
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                Text("\(state.text.count) 字符").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("清空") {
                    state.text = ""
                    state.content = .idle
                    model.cancelInputTranslation()
                    editorFocused = true
                }
                .buttonStyle(ActionButtonStyle(tint: .secondary))
                .disabled(state.text.isEmpty)
                Button {
                    model.translateInput()
                } label: {
                    HStack(spacing: 8) {
                        Text("翻译")
                        Text("⌘↩").font(.system(size: 11)).opacity(0.8)
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isEmpty)
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .frame(height: 52)
            .overlay(alignment: .top) { Divider() }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Result

    private var resultCard: some View {
        VStack(spacing: 0) {
            switch state.content {
            case .idle:
                VStack(spacing: 10) {
                    Image(systemName: "character.book.closed").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("译文会显示在这里").foregroundStyle(.secondary)
                    Text("⌘↩ 翻译").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading(let text):
                ScrollView {
                    ResultSkeleton(sourceText: text, kind: analysis?.kind ?? .text).padding(22)
                }
            case .result(let result):
                ScrollView {
                    ResultContent(result: result, style: .compact, speak: { speak(result) })
                        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
                }
                resultActions(result)
            case .error(let error):
                ScrollView {
                    ErrorCard(presentation: presentation(error), perform: perform, showsReturnHint: false)
                        .padding(20)
                }
            }
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultActions(_ result: TranslationResult) -> some View {
        HStack(spacing: 2) {
            Button {
                Pasteboard.copy(result.translation)
                state.copied = true
            } label: {
                Label(state.copied ? "已复制" : "复制", systemImage: state.copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(ActionButtonStyle())
            if result.kind == .word {
                Button { state.isFavorite = model.toggleFavorite(result) } label: {
                    Label(state.isFavorite ? "已收藏" : "收藏", systemImage: state.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(ActionButtonStyle(tint: state.isFavorite ? Theme.favorite : .primary))
            }
            Button { speak(result) } label: {
                Label(result.kind == .word ? "朗读" : "朗读原文", systemImage: "speaker.wave.2")
            }
            .buttonStyle(ActionButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .overlay(alignment: .top) { Divider() }
    }

    private func speak(_ result: TranslationResult) {
        model.speech.speak(result.word?.headword ?? result.sourceText, language: result.sourceLanguage)
    }

    private func presentation(_ error: FlowError) -> ErrorPresentation {
        if error == .invalidSelection {
            return .init(title: "没有可翻译的文字", message: "输入的内容里没有可翻译的文字。", symbol: "character.cursor.ibeam", tone: .warning)
        }
        return .make(error, shortcut: settings.shortcut.displayString, serviceLine: model.serviceLine)
    }

    private func perform(_ action: ErrorPresentation.Action) {
        switch action {
        case .retry: model.retryInputTranslation()
        case .openSettings: WindowRouter.shared.showSettings(.service)
        case .openAccessibility:
            SystemSelectionEnvironment.requestAccessibilityPrompt()
            SystemSelectionEnvironment.openAccessibilitySettings()
        }
    }
}
