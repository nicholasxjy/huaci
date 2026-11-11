import HuaciCore
import SwiftUI

func requireStore(_ store: HistoryStore?) throws -> HistoryStore {
    guard let store else { throw StoreError.sqlite("本地数据库不可用，请在设置 › 数据中查看错误。") }
    return store
}

/// Failed reads and mutations preserve the last successful list and its selection.
struct LibraryListState<Item: Identifiable> {
    private(set) var items: [Item] = []
    var selection: Item.ID?
    private(set) var warnings: [String] = []
    private(set) var error: String?

    mutating func reload(_ read: () throws -> StoreReadResult<Item>) {
        do {
            let snapshot = try read()
            items = snapshot.items
            warnings = snapshot.warnings
            error = nil
            if !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
        } catch {
            self.error = "读取失败，当前列表可能不是最新：\(error.localizedDescription)"
        }
    }

    mutating func delete(_ id: Item.ID, operation: () throws -> Void) -> Bool {
        do {
            try operation()
            if selection == id, let index = items.firstIndex(where: { $0.id == id }) {
                let next = items.indices.contains(index + 1) ? index + 1 : index - 1
                selection = items.indices.contains(next) ? items[next].id : nil
            }
            items.removeAll { $0.id == id }
            error = nil
            return true
        } catch {
            self.error = "删除失败，请重试读取以核实记录：\(error.localizedDescription)"
            return false
        }
    }

    mutating func clear(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            items = []
            selection = nil
            warnings = []
            error = nil
            return true
        } catch {
            self.error = "清空失败，请重试读取以核实记录：\(error.localizedDescription)"
            return false
        }
    }
}

private struct StorageNotice: View {
    let error: String?
    let warnings: [String]
    let retry: () -> Void

    var body: some View {
        if error != nil || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let error { Text(error).foregroundStyle(Theme.danger) }
                if !warnings.isEmpty {
                    Text("本次读取有 \(warnings.count) 条记录无法解码，原始数据已保留。总数包含这些记录；可在设置 › 数据中找到数据库文件。")
                    Text(warnings[0]).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("重试读取", action: retry)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

struct HistoryView: View {
    static let resultLimit = 500
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var list = LibraryListState<HistoryItem>()
    private var items: [HistoryItem] { list.items }
    /// "headword|target" of saved words, to mark them in the list.
    @State private var favoriteKeys: Set<String> = []
    @State private var favoriteIssue: String?
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
                Text("按时间最多显示最近 \(Self.resultLimit) 条；搜索全部历史，最多显示 \(Self.resultLimit) 条匹配记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                StorageNotice(error: list.error ?? favoriteIssue,
                              warnings: list.warnings, retry: reload)
                List(selection: $list.selection) {
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
                    if items.isEmpty && list.error == nil && list.warnings.isEmpty {
                        EmptyState(symbol: "clock", title: search.isEmpty ? "还没有查询记录" : "没有匹配的记录",
                                   detail: search.isEmpty ? "按 \(model.settings.shortcut.displayString) 翻译选中文字，记录会出现在这里。" : nil)
                    }
                }
            }
            .frame(width: 330)
            Divider()
            if let item = items.first(where: { $0.id == list.selection }) {
                DetailPane(meta: "\(Formatters.dayAndTime(item.createdAt)) · \(LanguageOption.chineseName(item.result.sourceLanguage)) → \(LanguageOption.chineseName(item.result.targetLanguage))",
                           result: item.result, speech: model.speech) {
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
                if list.clear({ try requireStore(model.store).clearHistory() }) {
                    model.dataChanged()
                }
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
        list.reload { try requireStore(model.store).historySnapshot(search: search, limit: Self.resultLimit) }
        do {
            let favorites = try requireStore(model.store).favoritesSnapshot()
            favoriteKeys = Set(favorites.items.map { "\($0.headword)|\($0.result.targetLanguage)" })
            favoriteIssue = favorites.warnings.isEmpty ? nil : "有 \(favorites.warnings.count) 条收藏无法读取，收藏标记可能不完整。\(favorites.warnings[0])"
        } catch {
            favoriteIssue = "无法读取收藏标记，当前标记可能不是最新：\(error.localizedDescription)"
        }
    }

    private func delete(_ id: Int64) {
        if list.delete(id, operation: { try requireStore(model.store).deleteHistory(id: id) }) {
            model.dataChanged()
        }
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
    @State private var list = LibraryListState<FavoriteItem>()
    private var items: [FavoriteItem] { list.items }
    @State private var total: Int?

    private var favoriteOrder: FavoriteOrder { FavoriteOrder(rawValue: order) ?? .recent }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ColumnHeader(title: "生词本", subtitle: list.error == nil ? total.map { "\($0) 个" } : "数量暂不可用") {
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
                StorageNotice(error: list.error, warnings: list.warnings, retry: reload)
                List(items, selection: $list.selection) { item in
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
                    if items.isEmpty && list.error == nil && list.warnings.isEmpty {
                        EmptyState(symbol: "star", title: search.isEmpty ? "生词本还是空的" : "没有匹配的单词",
                                   detail: search.isEmpty ? "在翻译浮窗中点击“收藏”或按 ⌘S 添加单词。" : nil)
                    }
                }
            }
            .frame(width: 300)
            Divider()
            if let item = items.first(where: { $0.id == list.selection }) {
                DetailPane(meta: "收藏于\(Formatters.dayAndTime(item.createdAt))", result: item.result, speech: model.speech) {
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
        list.reload {
            let store = try requireStore(model.store)
            let snapshot = try store.favoritesSnapshot(search: search, order: favoriteOrder)
            total = try store.favoritesCount()
            return snapshot
        }
    }

    private func delete(_ id: Int64) {
        if list.delete(id, operation: { try requireStore(model.store).deleteFavorite(id: id) }) {
            model.dataChanged()
        }
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
    let meta: String
    let result: TranslationResult
    @ObservedObject var speech: Speech
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
                SpeechActionButton(result: result, speech: speech)
                actions
            }
            .padding(.leading, 28)
            .padding(.trailing, 16)
            .frame(height: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(meta).font(.system(size: 12)).foregroundStyle(.secondary)
                    ResultContent(result: result, style: .detail, speak: { speech.toggle(result) },
                                  isSpeaking: speech.isSpeaking(result))
                }
                .frame(maxWidth: 560, alignment: .leading)
                    .padding(EdgeInsets(top: 12, leading: 32, bottom: 28, trailing: 32))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: result) { _ in copied = false }
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
