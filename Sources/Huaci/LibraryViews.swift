import HuaciCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var items: [HistoryItem] = []
    /// "headword|target" of saved words, to mark them in the list.
    @State private var favoriteKeys: Set<String> = []
    @State private var selection: Int64?
    @State private var confirmClear = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ColumnHeader(title: "历史") {
                    Button { confirmClear = true } label: { Image(systemName: "trash") }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .help("清空历史")
                        .accessibilityLabel("清空历史")
                        .disabled(items.isEmpty && search.isEmpty)
                }
                SearchField(text: $search, prompt: "搜索原文或译文")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                List(selection: $selection) {
                    ForEach(DayGrouping.group(items) { $0.createdAt }, id: \.day) { group in
                        Section(DayGrouping.label(for: group.day)) {
                            ForEach(group.items) { item in
                                HistoryRow(item: item, isFavorite: isFavorite(item.result))
                                    .tag(item.id)
                                    .contextMenu {
                                        Button("重新翻译") { model.retranslate(item.result) }
                                        Button("删除", role: .destructive) { delete(item.id) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if items.isEmpty {
                        EmptyState(symbol: "clock", title: search.isEmpty ? "还没有查询记录" : "没有匹配的记录",
                                   detail: search.isEmpty ? "按 \(model.settings.shortcut.displayString) 翻译选中文字，记录会出现在这里。" : nil)
                    }
                }
            }
            .frame(width: 330)
            Divider()
            if let item = items.first(where: { $0.id == selection }) {
                DetailPane(meta: "\(Formatters.dayAndTime(item.createdAt)) · \(LanguageOption.chineseName(item.result.sourceLanguage)) → \(LanguageOption.chineseName(item.result.targetLanguage))",
                           result: item.result) {
                    Button { model.retranslate(item.result) } label: { Label("重新翻译", systemImage: "arrow.clockwise") }
                        .buttonStyle(ActionButtonStyle())
                        .help("不使用缓存，重新请求模型")
                    Button { delete(item.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(ActionButtonStyle(tint: Theme.danger))
                        .help("删除这条记录")
                        .accessibilityLabel("删除这条记录")
                }
            } else {
                EmptyState(symbol: "text.alignleft", title: "选择一条记录查看详情")
            }
        }
        .confirmationDialog("清空全部查询历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                try? model.store?.clearHistory()
                model.dataChanged()
            }
        } message: {
            Text("此操作无法撤销，生词本不受影响。")
        }
        .onAppear(perform: reload)
        .onChange(of: search) { _ in reload() }
        .onReceive(model.$dataVersion) { _ in reload() }
    }

    private func isFavorite(_ result: TranslationResult) -> Bool {
        guard let word = result.word else { return false }
        return favoriteKeys.contains("\(word.headword)|\(result.targetLanguage)")
    }

    private func reload() {
        items = (try? model.store?.history(search: search)) ?? []
        favoriteKeys = Set(((try? model.store?.favorites()) ?? []).map { "\($0.headword)|\($0.result.targetLanguage)" })
        if selection == nil || !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
    }

    private func delete(_ id: Int64) {
        if selection == id, let index = items.firstIndex(where: { $0.id == id }) {
            let next = items.indices.contains(index + 1) ? index + 1 : index - 1
            selection = items.indices.contains(next) ? items[next].id : nil
        }
        try? model.store?.deleteHistory(id: id)
        model.dataChanged()
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let isFavorite: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            KindBadge(kind: item.result.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.result.sourceText.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.favorite)
                            .accessibilityLabel("已收藏")
                    }
                    Text(Formatters.time.string(from: item.createdAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(item.result.translation.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct KindBadge: View {
    let kind: TranslationKind

    var body: some View {
        Text(kind == .word ? "词" : "句")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(kind == .word ? Theme.accentText : .secondary)
            .frame(width: 20, height: 20)
            .background(kind == .word ? Theme.accentSoft : Theme.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(kind == .word ? "单词" : "句子")
    }
}

struct VocabularyView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("vocabularyOrder") private var order = FavoriteOrder.recent.rawValue
    @State private var search = ""
    @State private var items: [FavoriteItem] = []
    @State private var total = 0
    @State private var selection: Int64?

    private var favoriteOrder: FavoriteOrder { FavoriteOrder(rawValue: order) ?? .recent }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ColumnHeader(title: "生词本", subtitle: "\(total) 个") {
                    Menu {
                        Picker("排序", selection: $order) {
                            Text("最近添加").tag(FavoriteOrder.recent.rawValue)
                            Text("按字母").tag(FavoriteOrder.alphabetical.rawValue)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(favoriteOrder == .recent ? "最近添加" : "按字母").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                }
                SearchField(text: $search, prompt: "搜索单词或释义")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                List(items, selection: $selection) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.headword).font(Theme.headword(17)).lineLimit(1)
                            if let phonetic = item.result.word?.phonetic {
                                Text(phonetic).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text(item.result.translation).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(item.id)
                    .contextMenu {
                        Button("取消收藏", role: .destructive) { delete(item.id) }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if items.isEmpty {
                        EmptyState(symbol: "star", title: search.isEmpty ? "生词本还是空的" : "没有匹配的单词",
                                   detail: search.isEmpty ? "在翻译浮窗中点击“收藏”或按 ⌘S 添加单词。" : nil)
                    }
                }
            }
            .frame(width: 300)
            Divider()
            if let item = items.first(where: { $0.id == selection }) {
                DetailPane(meta: "收藏于\(Formatters.dayAndTime(item.createdAt))", result: item.result) {
                    Button { delete(item.id) } label: { Label("取消收藏", systemImage: "star.fill") }
                        .buttonStyle(ActionButtonStyle(tint: Theme.favorite))
                }
            } else {
                EmptyState(symbol: "book", title: "选择一个单词查看释义")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { _ in reload() }
        .onChange(of: order) { _ in reload() }
        .onReceive(model.$dataVersion) { _ in reload() }
    }

    private func reload() {
        items = (try? model.store?.favorites(search: search, order: favoriteOrder)) ?? []
        total = (try? model.store?.favoritesCount()) ?? 0
        if selection == nil || !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
    }

    private func delete(_ id: Int64) {
        if selection == id, let index = items.firstIndex(where: { $0.id == id }) {
            let next = items.indices.contains(index + 1) ? index + 1 : index - 1
            selection = items.indices.contains(next) ? items[next].id : nil
        }
        try? model.store?.deleteFavorite(id: id)
        model.dataChanged()
    }
}

/// Title row of a list column.
private struct ColumnHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            accessory
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 52)
    }
}

/// Selected history entry or saved word: actions on top, then the meta line
/// and the result in large type.
private struct DetailPane<Actions: View>: View {
    @EnvironmentObject private var model: AppModel
    let meta: String
    let result: TranslationResult
    @ViewBuilder let actions: Actions
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Button {
                    Pasteboard.copy(result.translation)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(ActionButtonStyle())
                Button { speak() } label: { Label("朗读", systemImage: "speaker.wave.2") }
                    .buttonStyle(ActionButtonStyle())
                actions
            }
            .padding(.leading, 28)
            .padding(.trailing, 16)
            .frame(height: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(meta).font(.system(size: 12)).foregroundStyle(.secondary)
                    ResultContent(result: result, style: .detail, speak: { speak() })
                }
                .frame(maxWidth: 560, alignment: .leading)
                    .padding(EdgeInsets(top: 12, leading: 32, bottom: 28, trailing: 32))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: result) { _ in copied = false }
    }

    private func speak() {
        model.speech.speak(result.word?.headword ?? result.sourceText, language: result.sourceLanguage)
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
