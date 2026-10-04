import HuaciCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var items: [HistoryItem] = []
    @State private var selection: Int64?
    @State private var confirmClear = false

    var body: some View {
        NavigationSplitView {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.result.sourceText).lineLimit(1)
                    Text(item.result.translation).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Text(item.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("删除", role: .destructive) { delete(item.id) }
                }
                .tag(item.id)
            }
            .overlay { if items.isEmpty { EmptyState(text: search.isEmpty ? "还没有查询记录" : "没有匹配的记录") } }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let item = items.first(where: { $0.id == selection }) {
                ResultDetail(result: item.result) {
                    Button("删除这条", role: .destructive) { delete(item.id) }
                }
            } else {
                EmptyState(text: "选择一条记录查看详情")
            }
        }
        .searchable(text: $search, prompt: "搜索原文或译文")
        .toolbar {
            Button("清空历史", role: .destructive) { confirmClear = true }.disabled(items.isEmpty && search.isEmpty)
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

    private func reload() {
        items = (try? model.store?.history(search: search)) ?? []
    }

    private func delete(_ id: Int64) {
        try? model.store?.deleteHistory(id: id)
        if selection == id { selection = nil }
        model.dataChanged()
    }
}

struct VocabularyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var items: [FavoriteItem] = []
    @State private var selection: Int64?
    @State private var confirmClear = false

    var body: some View {
        NavigationSplitView {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.headword).font(.headline)
                        if let phonetic = item.result.word?.phonetic {
                            Text(phonetic).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(item.result.translation).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("取消收藏", role: .destructive) { delete(item.id) }
                }
                .tag(item.id)
            }
            .overlay { if items.isEmpty { EmptyState(text: search.isEmpty ? "在翻译窗口点击“收藏”即可添加生词" : "没有匹配的单词") } }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let item = items.first(where: { $0.id == selection }) {
                ResultDetail(result: item.result) {
                    Button("取消收藏", role: .destructive) { delete(item.id) }
                }
            } else {
                EmptyState(text: "选择一个单词查看释义")
            }
        }
        .searchable(text: $search, prompt: "搜索单词或释义")
        .toolbar {
            Button("清空生词本", role: .destructive) { confirmClear = true }.disabled(items.isEmpty && search.isEmpty)
        }
        .confirmationDialog("清空全部生词？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                try? model.store?.clearFavorites()
                model.dataChanged()
            }
        } message: {
            Text("此操作无法撤销。")
        }
        .onAppear(perform: reload)
        .onChange(of: search) { _ in reload() }
        .onReceive(model.$dataVersion) { _ in reload() }
    }

    private func reload() {
        items = (try? model.store?.favorites(search: search)) ?? []
    }

    private func delete(_ id: Int64) {
        try? model.store?.deleteFavorite(id: id)
        if selection == id { selection = nil }
        model.dataChanged()
    }
}

private struct ResultDetail<Actions: View>: View {
    @EnvironmentObject private var model: AppModel
    let result: TranslationResult
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let word = result.word {
                WordResultView(result: result, word: word)
            } else {
                TextResultView(result: result)
            }
            Spacer(minLength: 0)
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.translation, forType: .string)
                } label: { Label("复制译文", systemImage: "doc.on.doc") }
                Button {
                    model.speech.speak(result.word?.headword ?? result.sourceText, language: result.sourceLanguage)
                } label: { Label("朗读", systemImage: "speaker.wave.2") }
                Spacer()
                actions
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EmptyState: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
