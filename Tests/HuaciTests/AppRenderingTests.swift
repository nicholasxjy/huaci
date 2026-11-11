import AppKit
import HuaciCore
import SwiftUI
import Testing
@testable import Huaci

@Suite(.serialized)
@MainActor
struct AppRenderingTests {
    @Test func mainSettingsAndPopupRenderWithIsolatedData() async throws {
        _ = NSApplication.shared
        let id = UUID().uuidString
        let suite = "app.huaci.render-tests.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("huaci-render-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, keychain: Keychain(service: suite), storeURL: directory.appendingPathComponent("test.sqlite"))
        #expect(model.storeError == nil)
        #expect(model.accounts.isEmpty)
        let result = TranslationResult(kind: .text, sourceText: "A complete translation.", sourceLanguage: "en",
                                       targetLanguage: "zh-Hans", translation: "一段完整的翻译。", word: nil)
        model.inputTranslation.text = result.sourceText
        model.inputTranslation.show(result: result, requestID: UUID())
        try model.store?.addHistory(result)
        try await render(MainWindowView(state: model.mainWindow).environmentObject(model).environmentObject(settings),
                         size: CGSize(width: 1040, height: 700), name: "main-translation")
        model.mainWindow.section = .history
        try await render(MainWindowView(state: model.mainWindow).environmentObject(model).environmentObject(settings),
                         size: CGSize(width: 1040, height: 700), name: "main-history")
        try await render(ServiceSettings().environmentObject(model).environmentObject(settings),
                         size: CGSize(width: 680, height: 560), name: "settings-service")
        settings.activeService = .chatGPT
        try await render(ServiceSettings().environmentObject(model).environmentObject(settings),
                         size: CGSize(width: 680, height: 560), name: "settings-suggestions")
        try await render(SettingsTab.data.content.environmentObject(model).environmentObject(settings),
                         size: CGSize(width: 680, height: 560), name: "settings-data")
        try await render(OnboardingView().environmentObject(model).environmentObject(settings),
                         size: CGSize(width: 720, height: 640), name: "onboarding-service")
        let state = PopupState()
        state.content = .result(result)
        state.modelName = "test-model"
        let actions = PopupActions(copy: { _ in }, toggleFavorite: { _ in }, retarget: { _ in }, togglePin: {},
                                   openInMainWindow: { _ in }, perform: { _ in }, close: {})
        try await render(PopupView(state: state, speech: model.speech, actions: actions),
                         size: CGSize(width: 400, height: 260), name: "popup-result")
        state.content = .loading("hello")
        try await render(PopupView(state: state, speech: model.speech, actions: actions),
                         size: CGSize(width: 400, height: 260), name: "popup-loading")
        state.content = .error(.translation(.timeout))
        try await render(PopupView(state: state, speech: model.speech, actions: actions),
                         size: CGSize(width: 400, height: 180), name: "popup-error")
        state.content = .hint("先选中文字，再按快捷键")
        try await render(PopupView(state: state, speech: model.speech, actions: actions),
                         size: CGSize(width: 400, height: 100), name: "popup-hint")
        state.content = .result(TranslationResult(kind: .word, sourceText: "hello", sourceLanguage: "en", targetLanguage: "zh-Hans",
                                                translation: "你好", word: WordEntry(headword: "hello", phonetic: "/həˈləʊ/",
                                                                                  senses: [WordSense(pos: "interj.", meanings: ["你好"])], examples: [])))
        state.storeError = "收藏未能更新，请重试。"
        try await render(PopupView(state: state, speech: model.speech, actions: actions),
                         size: CGSize(width: 400, height: 320), name: "popup-word-storage-warning")
    }

    private func render<Content: View>(_ content: Content, size: CGSize, name: String) async throws {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        defer { window.close() }
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let artifactPath = ProcessInfo.processInfo.environment["HUACI_UI_TEST_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: artifactPath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}
