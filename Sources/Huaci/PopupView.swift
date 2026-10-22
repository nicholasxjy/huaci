import HuaciCore
import SwiftUI

/// What the result window shows.
@MainActor
final class PopupState: ObservableObject {
    enum Content {
        case loading(String)
        case result(TranslationResult)
        case error(FlowError)
        /// Short-lived hint, e.g. when nothing was selected.
        case hint(String)
    }

    @Published var content: Content = .loading("")
    @Published var isFavorite = false
    @Published var copied = false
    /// Pinned panels stay open on outside clicks and can be dragged.
    @Published var isPinned = false
    @Published var modelName = ""
    /// Service and model, e.g. "ChatGPT 账号 · gpt-6-luna".
    @Published var serviceLine = ""
    @Published var shortcut = ""

    var result: TranslationResult? {
        if case .result(let result) = content { return result }
        return nil
    }
}

struct PopupActions {
    var copy: (String) -> Void
    var speak: (TranslationResult) -> Void
    var toggleFavorite: (TranslationResult) -> Void
    var retarget: (String) -> Void
    var togglePin: () -> Void
    var openInMainWindow: (TranslationResult) -> Void
    var perform: (ErrorPresentation.Action) -> Void
    var close: () -> Void
}

struct PopupView: View {
    static let width: CGFloat = 400
    static let maxBodyHeight: CGFloat = 420

    @ObservedObject var state: PopupState
    let actions: PopupActions

    var body: some View {
        switch state.content {
        case .hint(let text):
            hint(text)
        case .loading(let text):
            panel { loading(text) }
        case .result(let result):
            panel { resultView(result) }
        case .error(let error):
            panel {
                ErrorCard(presentation: .make(error, shortcut: state.shortcut, serviceLine: state.serviceLine),
                          perform: actions.perform, close: actions.close)
                    .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 14))
            }
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(width: Self.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Result

    private func resultView(_ result: TranslationResult) -> some View {
        Group {
            header {
                languageMenu(result)
                Spacer(minLength: 8)
                Text(state.modelName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.trailing, 4)
                pinButton
                closeButton
            }
            ScrollView {
                ResultContent(result: result, style: .compact, speak: { actions.speak(result) })
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 18, trailing: 20))
            }
            .frame(maxHeight: Self.maxBodyHeight)
            footer(result)
        }
    }

    /// "英语 → 简体中文"; choosing another language translates again, this time only.
    private func languageMenu(_ result: TranslationResult) -> some View {
        Menu {
            Section("临时译为") {
                ForEach(LanguageOption.all) { option in
                    Button {
                        actions.retarget(option.code)
                    } label: {
                        if option.code == result.targetLanguage {
                            Label(LanguageOption.chineseName(option.code), systemImage: "checkmark")
                        } else {
                            Text(LanguageOption.chineseName(option.code))
                        }
                    }
                }
            }
        } label: {
            Text("\(LanguageOption.chineseName(result.sourceLanguage)) → \(LanguageOption.chineseName(result.targetLanguage))")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("临时换一种目标语言")
    }

    private func footer(_ result: TranslationResult) -> some View {
        HStack(spacing: 2) {
            Button { actions.copy(result.translation) } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.copied ? "checkmark" : "doc.on.doc")
                    Text(state.copied ? "已复制" : "复制")
                    ShortcutHint(text: "⌘C")
                }
            }
            .buttonStyle(ActionButtonStyle())
            if result.kind == .word {
                Button { actions.toggleFavorite(result) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.isFavorite ? "star.fill" : "star")
                        Text(state.isFavorite ? "已收藏" : "收藏")
                        ShortcutHint(text: "⌘S")
                    }
                }
                .buttonStyle(ActionButtonStyle(tint: state.isFavorite ? Theme.favorite : .primary))
            }
            Button { actions.speak(result) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2")
                    Text(result.kind == .word ? "朗读" : "朗读原文")
                    ShortcutHint(text: "⌘R")
                }
            }
            .buttonStyle(ActionButtonStyle())
            Spacer(minLength: 0)
            Button { actions.openInMainWindow(result) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("在主窗口中编辑（⌘O）")
                .accessibilityLabel("在主窗口中编辑")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Loading

    private func loading(_ text: String) -> some View {
        Group {
            header {
                Text(state.modelName.isEmpty ? "正在翻译…" : "正在翻译 · \(state.modelName)")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                pinButton
                closeButton
            }
            IndeterminateBar()
            ResultSkeleton(sourceText: text, kind: TextAnalyzer.analyze(text, rules: LanguageRules())?.kind ?? .text)
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
            Text("按 Esc 取消")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: Pieces

    private func header<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2, content: content)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 38)
    }

    private var pinButton: some View {
        Button(action: actions.togglePin) { Image(systemName: state.isPinned ? "pin.fill" : "pin") }
            .buttonStyle(IconButtonStyle(active: state.isPinned))
            .help(state.isPinned ? "取消固定（⌘P）" : "固定浮窗：点击外部不关闭，可拖动（⌘P）")
            .accessibilityLabel(state.isPinned ? "取消固定" : "固定浮窗")
    }

    private var closeButton: some View {
        Button(action: actions.close) { Image(systemName: "xmark") }
            .buttonStyle(IconButtonStyle())
            .help("关闭（Esc）")
            .accessibilityLabel("关闭")
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "character.cursor.ibeam").font(.system(size: 13))
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 34)
        .background(Color(white: 0.16).opacity(0.92), in: Capsule())
        .fixedSize()
    }
}

/// Thin progress line under the popup header. Driven by a timeline rather
/// than a repeating animation, which would also animate the popup's layout.
struct IndeterminateBar: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            GeometryReader { geometry in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geometry.size.width * 0.34)
                    .offset(x: geometry.size.width * (1.34 * phase - 0.34))
            }
        }
        .frame(height: 2)
        .background(Color.primary.opacity(0.06))
        .clipped()
    }
}
