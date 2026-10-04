import HuaciCore
import SwiftUI

/// What the result window shows.
@MainActor
final class PopupState: ObservableObject {
    enum Content {
        case loading(String)
        case result(TranslationResult)
        case error(FlowError)
    }

    @Published var content: Content = .loading("")
    @Published var isFavorite = false
    @Published var copied = false
}

struct PopupActions {
    var copy: (String) -> Void
    var speak: (String, String?) -> Void
    var toggleFavorite: (TranslationResult) -> Void
    var retry: () -> Void
    var close: () -> Void
    var openSettings: () -> Void
    var openAccessibility: () -> Void
}

struct PopupView: View {
    static let width: CGFloat = 380
    static let maxBodyHeight: CGFloat = 380

    @ObservedObject var state: PopupState
    let actions: PopupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.content {
            case .loading(let text):
                loading(text)
            case .result(let result):
                if result.kind == .word, let word = result.word {
                    WordResultView(result: result, word: word, maxHeight: Self.maxBodyHeight)
                } else {
                    TextResultView(result: result, maxHeight: Self.maxBodyHeight)
                }
                toolbar(result)
            case .error(let error):
                errorView(error)
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private func loading(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("正在翻译…").font(.headline)
                if !text.isEmpty {
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            closeButton
        }
    }

    private func toolbar(_ result: TranslationResult) -> some View {
        HStack(spacing: 4) {
            Button { actions.copy(result.translation) } label: {
                Label(state.copied ? "已复制" : "复制译文", systemImage: state.copied ? "checkmark" : "doc.on.doc")
            }
            Button { actions.speak(result.word?.headword ?? result.sourceText, result.sourceLanguage) } label: {
                Label("朗读", systemImage: "speaker.wave.2")
            }
            if result.kind == .word {
                Button { actions.toggleFavorite(result) } label: {
                    Label(state.isFavorite ? "已收藏" : "收藏", systemImage: state.isFavorite ? "star.fill" : "star")
                }
            }
            Spacer(minLength: 0)
            closeButton
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
    }

    private func errorView(_ error: FlowError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error.userMessage).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                closeButton
            }
            HStack {
                switch error {
                case .capture(.permissionDenied):
                    Text("划词通过辅助功能读取选中文字；读取失败时会临时复制选区，并恢复原剪贴板。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置", action: actions.openAccessibility)
                case .translation(let translationError):
                    if case .notConfigured = translationError {
                        Button("打开设置", action: actions.openSettings)
                    } else if isRetryable(translationError) {
                        Button("重试", action: actions.retry)
                    }
                    if translationError == .unauthorized {
                        Button("设置", action: actions.openSettings)
                    }
                default:
                    EmptyView()
                }
            }
            .controlSize(.small)
        }
    }

    private var closeButton: some View {
        Button(action: actions.close) {
            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("关闭（Esc）")
    }

    private func isRetryable(_ error: TranslationError) -> Bool {
        switch error {
        case .network, .timeout, .invalidResponse, .http, .rateLimited: return true
        default: return false
        }
    }
}

/// Dictionary-style entry; also used in the history and vocabulary windows.
struct WordResultView: View {
    let result: TranslationResult
    let word: WordEntry
    var maxHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(word.headword).font(.title2.weight(.semibold)).textSelection(.enabled)
                if let phonetic = word.phonetic {
                    Text(phonetic).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text(result.translation).font(.headline).textSelection(.enabled)
            ScrollView {
                details.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(word.senses.enumerated()), id: \.offset) { _, sense in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let pos = sense.pos {
                        Text(pos).font(.caption.monospaced()).foregroundStyle(.secondary).frame(minWidth: 32, alignment: .leading)
                    }
                    Text(sense.meanings.joined(separator: "；")).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !word.examples.isEmpty {
                Divider()
                ForEach(Array(word.examples.enumerated()), id: \.offset) { _, example in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.source).italic().fixedSize(horizontal: false, vertical: true)
                        if let translation = example.translation {
                            Text(translation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// Sentence or paragraph translation with the source for reference.
struct TextResultView: View {
    let result: TranslationResult
    var maxHeight: CGFloat? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(result.translation)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text(result.sourceText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
    }
}
