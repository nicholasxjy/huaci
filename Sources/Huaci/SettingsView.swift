import AppKit
import Combine
import HuaciCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general
    case service
    case language
    case data
    case about

    var title: String {
        switch self {
        case .general: return "通用"
        case .service: return "翻译服务"
        case .language: return "语言"
        case .data: return "数据"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .service: return "globe"
        case .language: return "character.bubble"
        case .data: return "internaldrive"
        case .about: return "info.circle"
        }
    }

    @MainActor @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .service: ServiceSettings()
        case .language: LanguageSettings()
        case .data: DataSettings()
        case .about: AboutView()
        }
    }
}

/// Settings window: toolbar tabs, the window title follows the selected tab.
final class SettingsTabController: NSTabViewController {
    static let contentSize = CGSize(width: 680, height: 560)

    init(model: AppModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let root = tab.content
                .environmentObject(model)
                .environmentObject(model.settings)
                .tint(Theme.accent)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
            let host = NSHostingController(rootView: root)
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { nil }

    func select(_ tab: SettingsTab) {
        if let index = SettingsTab.allCases.firstIndex(of: tab) { selectedTabViewItemIndex = index }
        view.window?.title = tab.title
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "设置"
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("翻译选中文字") { ShortcutRecorder() }
            } header: {
                Text("快捷键")
            } footer: {
                Footnote(text: "点击后直接按下新的组合键；按 Esc 取消，按 ⌫ 恢复默认。")
            }
            Section {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                .toggleStyle(.switch)
                if loginItemStatus == .requiresApproval {
                    LabeledContent("需要在系统设置 › 通用 › 登录项中允许划词。") {
                        Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .foregroundStyle(.secondary)
                }
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(Theme.danger)
                }
            } header: {
                Text("启动")
            }
            Section {
                LabeledContent("辅助功能") {
                    if model.accessibilityTrusted {
                        StatusBadge(text: "已开启", tone: .success, symbol: "checkmark")
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
                Footnote(text: "用于读取其他应用中选中的文字；读不到时会临时复制选区，取词后恢复原剪贴板。重新安装或更新应用后，可能需要在系统设置中重新勾选。")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            model.refreshAccessibility()
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "无法\(enabled ? "开启" : "关闭")开机启动：\(error.localizedDescription)"
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}

// MARK: - Language

private struct LanguageSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.foreignTarget) {
                    ForEach(LanguageOption.all) { Text($0.displayName).tag($0.code) }
                } label: {
                    RuleLabel(title: "选中外文时", detail: "English、日本語、Français …")
                }
                Picker(selection: $settings.chineseTarget) {
                    ForEach(LanguageOption.all.filter { !$0.code.hasPrefix("zh") }) { Text($0.displayName).tag($0.code) }
                } label: {
                    RuleLabel(title: "选中中文时", detail: "简体或繁体")
                }
            } header: {
                Text("翻译方向 · 自动识别原文语言")
            } footer: {
                Footnote(text: "原文与目标语言相同时，改译为简体中文。")
            }
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                    Text("偶尔需要别的语言？在浮窗顶部点击「英语 → 简体中文」即可临时换一种目标语言，只对当次生效。")
                        .foregroundStyle(Theme.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13))
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuleLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Data

private struct DataSettings: View {
    enum ClearTarget: String, Identifiable {
        case history, favorites, cache
        var id: String { rawValue }

        var question: String {
            switch self {
            case .history: return "清空全部查询历史？"
            case .favorites: return "清空生词本？"
            case .cache: return "清除全部翻译缓存？"
            }
        }

        var detail: String {
            switch self {
            case .history: return "此操作无法撤销，生词本不受影响。"
            case .favorites: return "此操作无法撤销。"
            case .cache: return "之后的查询会重新请求模型。查询历史与生词本不受影响。"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var historyCount = 0
    @State private var favoritesCount = 0
    @State private var cacheCount = 0
    @State private var clearTarget: ClearTarget?

    var body: some View {
        Form {
            Section("本机数据") {
                row("查询历史", "\(historyCount) 条") {
                    Button("查看") { WindowRouter.shared.showMain(.history) }
                    Button("清空…", role: .destructive) { clearTarget = .history }.disabled(historyCount == 0)
                }
                row("生词本", "\(favoritesCount) 个") {
                    Button("查看") { WindowRouter.shared.showMain(.vocabulary) }
                    Button("清空…", role: .destructive) { clearTarget = .favorites }.disabled(favoritesCount == 0)
                }
                row("翻译缓存", "\(cacheCount.formatted()) 条 · 相同内容再次查询时直接使用") {
                    Button("清除…", role: .destructive) { clearTarget = .cache }.disabled(cacheCount == 0)
                }
            }
            if let url = model.store?.url {
                Section {
                    HStack {
                        Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } header: {
                    Text("存储位置")
                } footer: {
                    Footnote(text: "所有数据只保存在这台 Mac 上。API Key 与登录凭据在钥匙串中，不在此文件里。")
                }
            }
            if let error = model.storeError {
                Text(error).foregroundStyle(Theme.danger)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(clearTarget?.question ?? "", isPresented: Binding(get: { clearTarget != nil }, set: { if !$0 { clearTarget = nil } }),
                            presenting: clearTarget) { target in
            Button(target == .cache ? "清除" : "清空", role: .destructive) { clear(target) }
        } message: { target in
            Text(target.detail)
        }
        .onAppear(perform: reload)
        .onReceive(model.$dataVersion) { _ in reload() }
    }

    private func row<Buttons: View>(_ title: String, _ detail: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            buttons()
        }
    }

    private func clear(_ target: ClearTarget) {
        switch target {
        case .history: try? model.store?.clearHistory()
        case .favorites: try? model.store?.clearFavorites()
        case .cache: model.clearTranslationCache()
        }
        model.dataChanged()
    }

    private func reload() {
        historyCount = (try? model.store?.historyCount()) ?? 0
        favoritesCount = (try? model.store?.favoritesCount()) ?? 0
        cacheCount = (try? model.store?.translationCacheCount()) ?? 0
    }
}

// MARK: - About

private struct AboutView: View {
    private static let repository = URL(string: "https://github.com/nicholasxjy/huaci")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("划词").font(.system(size: 26, weight: .bold)).padding(.top, 4)
                HStack(spacing: 6) {
                    Text("Huaci · 版本 \(version)").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button {
                        Pasteboard.copy("划词 Huaci \(version)，macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("复制版本信息")
                    .accessibilityLabel("复制版本信息")
                }
                Text("macOS 菜单栏划词翻译。在任意应用中选中文字，按下快捷键，翻译就出现在鼠标旁边。")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
                    .padding(.top, 6)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                FeatureCard(symbol: "book", title: "词典式释义", detail: "单词显示音标、词性、释义和例句，可朗读、可收藏到生词本。")
                FeatureCard(symbol: "character.book.closed", title: "句子与段落", detail: "自动识别语言和内容类型，外文译成中文，中文译成英文。")
                FeatureCard(symbol: "globe", title: "三种翻译服务", detail: "个人 API（OpenAI 兼容）、ChatGPT 账号、Antigravity，随时切换。")
                FeatureCard(symbol: "lock.shield", title: "数据留在本机", detail: "密钥存于钥匙串；历史、生词本与缓存存于本地数据库。")
            }

            HStack(spacing: 10) {
                link("GitHub 项目主页", symbol: "arrow.up.right.square", url: Self.repository)
                link("反馈问题", symbol: "bubble.left", url: Self.repository.appendingPathComponent("issues"))
                link("开源许可", symbol: "doc.text", url: Self.repository.appendingPathComponent("blob/main/LICENSE"))
            }

            Spacer(minLength: 0)

            VStack(spacing: 4) {
                Text("原文只发送给你选择的翻译服务，划词本身不收集任何数据。")
                Text("MIT License · © 2026 jy")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(EdgeInsets(top: 28, leading: 40, bottom: 20, trailing: 40))
    }

    private func link(_ title: String, symbol: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: { Label(title, systemImage: symbol) }
            .help(url.absoluteString)
    }
}

private struct FeatureCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
