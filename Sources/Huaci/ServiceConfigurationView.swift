import HuaciCore
import SwiftUI

/// Personal OpenAI-compatible API settings; shared by settings and onboarding.
struct ServiceConfigurationView: View {
    var body: some View {
        PersonalAPIForm()
    }
}

private struct PersonalAPIForm: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var busy = false
    @State private var testMessage: String?
    @State private var testFailed = false

    var body: some View {
        TextField("服务地址", text: $settings.personalBaseURL, prompt: Text("https://api.openai.com/v1"))
        SecureField("API Key", text: $apiKey, prompt: Text(hasSavedKey ? "已保存；输入新 Key 可替换" : "sk-…"))
        TextField("模型", text: $settings.personalModel, prompt: Text("例如 gpt-4o-mini"))

        HStack {
            Button("保存") { save() }.disabled(apiKey.isEmpty)
            Button("测试连接") { Task { await test() } }.disabled(busy)
            if hasSavedKey {
                Button("删除 Key", role: .destructive) {
                    model.keychain.delete(.personalAPIKey)
                    hasSavedKey = false
                }
            }
            if busy { ProgressView().controlSize(.small) }
        }
        if let testMessage {
            Text(testMessage).font(.callout).foregroundStyle(testFailed ? .red : .green)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("支持 OpenAI 兼容的 Chat Completions 接口。API Key 只保存在本机钥匙串，并且只发送到上面的服务地址。")
            .font(.caption).foregroundStyle(.secondary)
            .onAppear { hasSavedKey = model.keychain.read(.personalAPIKey) != nil }
    }

    private func save() {
        if model.keychain.write(apiKey, for: .personalAPIKey) {
            apiKey = ""
            hasSavedKey = true
            testMessage = "已保存。"
            testFailed = false
        } else {
            testMessage = "保存到钥匙串失败。"
            testFailed = true
        }
    }

    private func test() async {
        if !apiKey.isEmpty { save() }
        busy = true
        defer { busy = false }
        let request = TranslationRequest(text: "hello", kind: .word, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
        do {
            let result = try await model.makeTranslator().translate(request)
            testMessage = "连接成功：hello → \(result.translation)"
            testFailed = false
        } catch {
            testMessage = (error as? TranslationError)?.userMessage ?? error.localizedDescription
            testFailed = true
        }
    }
}
