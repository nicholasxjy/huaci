import HuaciCore
import SwiftUI

/// Type sizes for the places a result is shown.
enum ResultStyle {
    /// Floating popup and the translate tab's result card.
    case compact
    /// Detail pane of the history and vocabulary tabs.
    case detail

    var headword: CGFloat { self == .compact ? 30 : 44 }
    var meaning: CGFloat { self == .compact ? 17 : 20 }
    var body: CGFloat { self == .compact ? 14 : 15 }
    var secondary: CGFloat { self == .compact ? 13 : 14 }
}

/// Dictionary-style entry: headword, phonetic, main meaning, senses, examples.
struct WordEntryView: View {
    let result: TranslationResult
    let word: WordEntry
    var style: ResultStyle = .compact
    var speak: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: style == .compact ? 6 : 10) {
                Text(word.headword)
                    .font(Theme.headword(style.headword))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let speak {
                    Button(action: speak) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
                            if let phonetic = word.phonetic { Text(phonetic) } else { Text("朗读") }
                        }
                        .font(.system(size: style == .compact ? 13 : 14))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 9)
                        .frame(height: style == .compact ? 24 : 28)
                        .background(Theme.accentSoft, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("朗读")
                    .accessibilityLabel("朗读 \(word.headword)")
                } else if let phonetic = word.phonetic {
                    Text(phonetic).font(.system(size: style.secondary)).foregroundStyle(.secondary)
                }
            }

            Text(result.translation)
                .font(.system(size: style.meaning, weight: .semibold))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !word.senses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(word.senses.enumerated()), id: \.offset) { _, sense in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if let pos = sense.pos, !pos.isEmpty { PartOfSpeechBadge(text: pos) }
                            Text(sense.meanings.joined(separator: "；"))
                                .font(.system(size: style.body))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !word.examples.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(word.examples.enumerated()), id: \.offset) { index, example in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.highlighted(example.source, term: word.headword))
                                    .font(.system(size: style.body))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let translation = example.translation {
                                    Text(translation)
                                        .font(.system(size: style.secondary))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Marks each occurrence of the headword in an example sentence.
    static func highlighted(_ text: String, term: String) -> AttributedString {
        var output = AttributedString()
        var rest = text[...]
        let term = term.trimmingCharacters(in: .whitespaces)
        while !term.isEmpty, let range = rest.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            output += AttributedString(String(rest[..<range.lowerBound]))
            var hit = AttributedString(String(rest[range]))
            hit.inlinePresentationIntent = .stronglyEmphasized
            hit.foregroundColor = Theme.accentText
            output += hit
            rest = rest[range.upperBound...]
        }
        output += AttributedString(String(rest))
        return output
    }
}

struct PartOfSpeechBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 30, minHeight: 20)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Sentence or paragraph: the translation first, the source below.
struct TextTranslationView: View {
    let result: TranslationResult
    var style: ResultStyle = .compact
    /// Compact style folds the source to two lines.
    @State private var sourceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 14 : 20) {
            Text(result.translation)
                .font(.system(size: style == .compact ? 16 : 20, weight: style == .compact ? .regular : .medium))
                .lineSpacing(style == .compact ? 5 : 7)
                .fixedSize(horizontal: false, vertical: true)
            if style == .compact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("原文").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button(sourceExpanded ? "收起" : "展开") { sourceExpanded.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(result.sourceText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .lineLimit(sourceExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(result.sourceText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Either kind of result.
struct ResultContent: View {
    let result: TranslationResult
    var style: ResultStyle = .compact
    var speak: (() -> Void)?

    var body: some View {
        if result.kind == .word, let word = result.word {
            WordEntryView(result: result, word: word, style: style, speak: speak)
        } else {
            TextTranslationView(result: result, style: style)
        }
    }
}

/// Placeholder shaped like the expected result while it loads.
struct ResultSkeleton: View {
    let sourceText: String
    let kind: TranslationKind

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if kind == .word {
                Text(sourceText).font(Theme.headword(30)).lineLimit(2)
                SkeletonBar(width: 220, height: 14)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) { SkeletonBar(width: 30, height: 14); SkeletonBar() }
                    HStack(spacing: 10) { SkeletonBar(width: 30, height: 14); SkeletonBar(width: 180) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) { SkeletonBar(width: 300); SkeletonBar(width: 190) }
            } else {
                VStack(alignment: .leading, spacing: 9) { SkeletonBar(); SkeletonBar(); SkeletonBar(width: 200) }
                Text(sourceText).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How a failed lookup is presented: one title, one explanation, at most one
/// primary action.
struct ErrorPresentation {
    enum Action { case openAccessibility, openSettings, retry }
    enum Tone { case warning, danger }

    var title: String
    var message: String
    var symbol: String
    var tone: Tone
    var action: Action?
    /// Shown as a short-lived hint instead of a panel.
    var isHint = false

    var actionTitle: String? {
        switch action {
        case .openAccessibility: return "打开系统设置"
        case .openSettings: return "打开设置"
        case .retry: return "重试"
        case nil: return nil
        }
    }

    /// `serviceLine` names the service and model, e.g. "ChatGPT 账号 · gpt-6-luna".
    static func make(_ error: FlowError, shortcut: String, serviceLine: String) -> ErrorPresentation {
        switch error {
        case .capture(.permissionDenied):
            return .init(title: "需要辅助功能权限",
                         message: "划词需要读取你选中的文字。开启后回到这里再按一次 \(shortcut) 即可。",
                         symbol: "lock.shield", tone: .warning, action: .openAccessibility)
        case .capture(.copyTimedOut), .capture(.noText), .invalidSelection:
            return .init(title: "先选中一些文字，再按 \(shortcut)", message: "", symbol: "character.cursor.ibeam",
                         tone: .warning, isHint: true)
        case .capture(let failure):
            return .init(title: "无法读取选中的文字", message: failure.userMessage, symbol: "exclamationmark.triangle",
                         tone: .warning)
        case .translation(let failure):
            switch failure {
            case .notConfigured(let detail):
                return .init(title: "还没有配置翻译服务", message: detail, symbol: "gearshape", tone: .warning, action: .openSettings)
            case .unauthorized:
                return .init(title: "认证失败", message: "\(serviceLine) 拒绝了请求：API Key 无效、登录已失效或没有权限。",
                             symbol: "person.crop.circle.badge.exclamationmark", tone: .danger, action: .openSettings)
            case .timeout:
                return .init(title: "请求超时", message: "\(serviceLine) 没有及时响应。", symbol: "clock.badge.exclamationmark",
                             tone: .danger, action: .retry)
            case .network:
                return .init(title: "网络连接失败", message: failure.userMessage, symbol: "wifi.exclamationmark",
                             tone: .danger, action: .retry)
            case .rateLimited:
                return .init(title: "请求过于频繁", message: failure.userMessage, symbol: "hourglass", tone: .warning, action: .retry)
            case .inputTooLong:
                return .init(title: "选中的文字太长", message: failure.userMessage, symbol: "text.badge.xmark", tone: .warning)
            case .http, .rejected, .invalidResponse:
                return .init(title: "翻译服务出错", message: failure.userMessage, symbol: "exclamationmark.circle",
                             tone: .danger, action: .retry)
            case .cancelled:
                return .init(title: "已取消", message: "", symbol: "xmark.circle", tone: .warning)
            }
        }
    }
}

/// Icon tile, title, message and the primary action of an error.
struct ErrorCard: View {
    let presentation: ErrorPresentation
    let perform: (ErrorPresentation.Action) -> Void
    var close: (() -> Void)?
    /// The popup runs the action on Return; text fields elsewhere use Return themselves.
    var showsReturnHint = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(presentation.tone == .warning ? Theme.warning : Theme.danger)
                .frame(width: 36, height: 36)
                .background(presentation.tone == .warning ? Theme.warningSoft : Theme.dangerSoft,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.title).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, close == nil ? 0 : 24)
                if !presentation.message.isEmpty {
                    Text(presentation.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let action = presentation.action, let title = presentation.actionTitle {
                    HStack(spacing: 8) {
                        Button {
                            perform(action)
                        } label: {
                            if action == .retry { Label(title, systemImage: "arrow.clockwise") } else { Text(title) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                        if showsReturnHint {
                            Text("或按 ↩").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) {
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("关闭（Esc）")
                    .accessibilityLabel("关闭")
                    .offset(y: -2)
            }
        }
    }
}
