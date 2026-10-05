import Combine
import HuaciCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Form { ServiceConfigurationView() }
                .formStyle(.grouped)
                .tabItem { Label("翻译服务", systemImage: "network") }
            LanguageSettings()
                .tabItem { Label("语言", systemImage: "globe") }
            GeneralSettings()
                .tabItem { Label("快捷键与权限", systemImage: "keyboard") }
            CacheSettings()
                .tabItem { Label("缓存", systemImage: "internaldrive") }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct LanguageSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("外文译为", selection: $settings.foreignTarget) {
                    ForEach(LanguageOption.all) { Text($0.displayName).tag($0.code) }
                }
                Picker("中文译为", selection: $settings.chineseTarget) {
                    ForEach(LanguageOption.all.filter { !$0.code.hasPrefix("zh") }) { Text($0.displayName).tag($0.code) }
                }
            } footer: {
                Text("自动识别原文语言：中文按“中文译为”，其他语言按“外文译为”。原文与目标语言相同时改译为简体中文。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("快捷键") {
                LabeledContent("翻译选中文字") { ShortcutRecorder() }
            }
            Section {
                LabeledContent("辅助功能") {
                    if model.accessibilityTrusted {
                        Label("已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("开启…") {
                            SystemSelectionEnvironment.requestAccessibilityPrompt()
                            SystemSelectionEnvironment.openAccessibilitySettings()
                        }
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("划词通过辅助功能读取其他应用中选中的文字；读取不到时会临时发送 ⌘C 复制选区，取词后恢复原剪贴板。重新安装或更新应用后，可能需要在系统设置中重新勾选。")
            }
            Section("本地数据") {
                HStack {
                    Button("查询历史…") { WindowRouter.shared.showHistory() }
                    Button("生词本…") { WindowRouter.shared.showVocabulary() }
                }
                if let error = model.storeError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in model.refreshAccessibility() }
    }
}

private struct CacheSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var items: [CachedTranslation] = []
    @State private var count = 0
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                LabeledContent("已缓存") { Text("\(count) 条") }
                if let url = model.store?.url {
                    LabeledContent("缓存文件") {
                        HStack {
                            Text(url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("全部清除", role: .destructive) { confirmClear = true }.disabled(count == 0)
                }
            } header: {
                Text("翻译缓存")
            } footer: {
                Text("相同原文、类型与目标语言再次查询时直接使用缓存结果，不再请求模型。切换服务或模型不会使缓存失效；清除后会重新请求模型。缓存与历史、生词本存放在同一个数据库文件中，清除缓存不影响它们。")
            }
            Section(count > items.count ? "最近 \(items.count) 条" : "缓存条目") {
                if items.isEmpty {
                    Text("暂无缓存").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.result.sourceText).lineLimit(1)
                        Text(item.result.translation).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(LanguageOption.named(item.result.targetLanguage).displayName) · \(item.createdAt.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if let error = model.storeError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清除全部翻译缓存？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { model.clearTranslationCache() }
        } message: {
            Text("之后的查询会重新请求模型。查询历史与生词本不受影响。")
        }
        .onAppear(perform: reload)
        .onReceive(model.$dataVersion) { _ in reload() }
    }

    private func reload() {
        items = (try? model.store?.cachedTranslations()) ?? []
        count = (try? model.store?.translationCacheCount()) ?? 0
    }
}
