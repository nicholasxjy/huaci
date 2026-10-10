import AppKit
import HuaciCore
import SwiftUI

/// State of the typed-text translation window; presents its own flow's results.
@MainActor
final class InputTranslationState: ObservableObject, TranslationPresenter {
    enum Content {
        case idle
        case loading
        case result(TranslationResult)
        case error(FlowError)
    }

    @Published var text = ""
    @Published var content: Content = .idle
    @Published var isFavorite = false
    @Published var copied = false

    /// Set by the model, which owns favorites.
    var isFavoriteResult: (TranslationResult) -> Bool = { _ in false }

    func showLoading(requestID: UUID, sourceText: String) {
        content = .loading
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

struct InputTranslationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var state: InputTranslationState
    @FocusState private var editorFocused: Bool

    private var isEmpty: Bool { state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.text)
                    .font(.body)
                    .focused($editorFocused)
                if state.text.isEmpty {
                    Text("输入要翻译的单词或句子")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 90, maxHeight: 160)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            HStack {
                Text("⌘↩ 翻译").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空") {
                    state.text = ""
                    state.content = .idle
                    model.cancelInputTranslation()
                    editorFocused = true
                }
                .disabled(state.text.isEmpty)
                Button("翻译") { model.translateInput() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty)
            }

            Divider()

            output
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .onAppear { editorFocused = true }
    }

    @ViewBuilder
    private var output: some View {
        switch state.content {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在翻译…").foregroundStyle(.secondary)
            }
        case .result(let result):
            VStack(alignment: .leading, spacing: 10) {
                if result.kind == .word, let word = result.word {
                    WordResultView(result: result, word: word)
                } else {
                    TextResultView(result: result)
                }
                toolbar(result)
            }
        case .error(let error):
            errorView(error)
        }
    }

    private func toolbar(_ result: TranslationResult) -> some View {
        HStack(spacing: 4) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.translation, forType: .string)
                state.copied = true
            } label: {
                Label(state.copied ? "已复制" : "复制译文", systemImage: state.copied ? "checkmark" : "doc.on.doc")
            }
            Button { model.speech.speak(result.word?.headword ?? result.sourceText, language: result.sourceLanguage) } label: {
                Label("朗读", systemImage: "speaker.wave.2")
            }
            if result.kind == .word {
                Button { state.isFavorite = model.toggleFavorite(result) } label: {
                    Label(state.isFavorite ? "已收藏" : "收藏", systemImage: state.isFavorite ? "star.fill" : "star")
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
    }

    private func errorView(_ error: FlowError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error == .invalidSelection ? "输入的内容里没有可翻译的文字。" : error.userMessage)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .translation(let translationError) = error {
                HStack {
                    switch translationError {
                    case .notConfigured, .unauthorized:
                        Button("打开设置") { WindowRouter.shared.showSettings() }
                    case .cancelled, .inputTooLong:
                        EmptyView()
                    default:
                        Button("重试") { model.retryInputTranslation() }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
