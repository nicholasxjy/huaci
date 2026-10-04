import HuaciCore
import SwiftUI

/// Picks the active translation service and configures it; shared by settings
/// and onboarding.
struct ServiceConfigurationView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section {
            Picker("当前服务", selection: $settings.activeService) {
                ForEach(TranslationService.allCases) { Text($0.displayName).tag($0) }
            }
        } footer: {
            Text("各服务的配置和登录状态分别保存，可随时在这里或菜单栏切换。")
        }
        Section(settings.activeService.displayName) {
            switch settings.activeService {
            case .personalAPI:
                PersonalAPIForm()
            case .chatGPT:
                OAuthServiceForm(
                    service: .chatGPT,
                    model: $settings.chatGPTModel,
                    note: "使用 ChatGPT 订阅（Plus/Pro 等）的额度，与 Codex CLI 的“Sign in with ChatGPT”相同。登录凭据只保存在本机钥匙串。",
                    warning: nil
                )
            case .antigravity:
                OAuthServiceForm(
                    service: .antigravity,
                    model: $settings.antigravityModel,
                    note: "使用 Google 账号在 Antigravity 中的模型额度。登录凭据只保存在本机钥匙串。",
                    warning: "这是非官方接入方式，可能违反 Google 服务条款；有用户报告账号因此被限制或封禁。请自行评估风险，建议不要使用重要账号。"
                )
            }
        }
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
            .onAppear { hasSavedKey = model.keychain.contains(.personalAPIKey) }
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
        (testMessage, testFailed) = await model.testConnection()
    }
}

/// Browser sign-in, model choice and connection test for an OAuth service.
private struct OAuthServiceForm: View {
    let service: TranslationService
    @Binding var model: String
    let note: String
    let warning: String?

    @EnvironmentObject private var appModel: AppModel
    @State private var signInTask: Task<Void, Never>?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        LabeledContent("账号") {
            if let account = appModel.accounts[service] {
                HStack {
                    Text(account.email ?? "已登录").textSelection(.enabled)
                    Button("退出登录") {
                        message = nil
                        Task { await appModel.signOut(service) }
                    }
                }
            } else if signInTask != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器中完成授权…").foregroundStyle(.secondary)
                    Button("取消") { signInTask?.cancel() }
                }
            } else if appModel.auth(for: service)?.provider.isClientConfigured == false {
                Text("此版本未配置 OAuth 客户端，见 README").foregroundStyle(.secondary)
            } else {
                Button("使用浏览器登录…") { signIn() }
            }
        }
        // Frees the callback port when the form goes away mid sign-in.
        .onDisappear { signInTask?.cancel() }
        HStack {
            TextField("模型", text: $model, prompt: Text(service.suggestedModels.first ?? ""))
            Menu("常用") {
                ForEach(service.suggestedModels, id: \.self) { name in
                    Button(name) { model = name }
                }
            }
            .fixedSize()
        }
        HStack {
            Button("测试连接") {
                Task {
                    busy = true
                    (message, failed) = await appModel.testConnection()
                    busy = false
                }
            }
            .disabled(busy || appModel.accounts[service] == nil)
            if busy { ProgressView().controlSize(.small) }
        }
        if let message {
            Text(message).font(.callout).foregroundStyle(failed ? .red : .green)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(note).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let warning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signIn() {
        message = nil
        signInTask = Task {
            do {
                try await appModel.signIn(service)
                message = "登录成功。"
                failed = false
            } catch TranslationError.cancelled {
                message = nil
            } catch {
                message = (error as? TranslationError)?.userMessage ?? error.localizedDescription
                failed = true
            }
            signInTask = nil
        }
    }
}
