import HuaciCore
import SwiftUI

/// Settings tab: service cards on top, the active service's form below.
struct ServiceSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            ServiceCards()
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                ServiceForm(service: settings.activeService)
            }
            .formStyle(.grouped)
        }
    }
}

/// One selectable card per service, with its status.
struct ServiceCards: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(TranslationService.allCases) { service in
                card(service)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("翻译服务")
    }

    private func card(_ service: TranslationService) -> some View {
        let selected = settings.activeService == service
        return Button {
            settings.activeService = service
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: service.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : .primary)
                    .frame(width: 32, height: 32)
                    .background(selected ? Theme.accentSoft : Theme.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.shortName).font(.system(size: 13, weight: .semibold))
                    Text(service.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    status(service, selected: selected)
                    if service == .antigravity { StatusBadge(text: "非官方", tone: .warning) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.accent.opacity(selected ? 0.14 : 0), lineWidth: 4)
                    .padding(-2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func status(_ service: TranslationService, selected: Bool) -> some View {
        if model.isConfigured(service) {
            StatusBadge(text: selected ? "使用中" : (service.usesOAuth ? "已登录" : "已配置"), tone: .success, dot: true)
        } else {
            StatusBadge(text: service.usesOAuth ? "未登录" : "未配置", tone: selected ? .warning : .neutral)
        }
    }
}

/// The form section of one service.
struct ServiceForm: View {
    let service: TranslationService
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        switch service {
        case .personalAPI:
            PersonalAPIForm()
        case .chatGPT:
            OAuthServiceForm(
                service: .chatGPT,
                model: $settings.chatGPTModel,
                note: "使用 ChatGPT Plus / Pro 订阅额度，与 Codex CLI 的 “Sign in with ChatGPT” 相同。登录凭据只保存在本机钥匙串。",
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

struct PersonalAPIForm: View {
    /// Onboarding shows the form inside the service's own card.
    var showsHeader = true
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Section {
            TextField("服务地址", text: $settings.personalBaseURL, prompt: Text("https://api.openai.com/v1"))
            SecureField("API Key", text: $apiKey, prompt: Text(hasSavedKey ? "已保存；输入新 Key 可替换" : "sk-…"))
                .onSubmit(save)
            if hasSavedKey || !apiKey.isEmpty {
                LabeledContent("钥匙串") {
                    HStack(spacing: 8) {
                        if !apiKey.isEmpty {
                            Button("保存 Key", action: save)
                        } else {
                            Text("已保存").foregroundStyle(.secondary)
                            Button("删除", role: .destructive) {
                                model.keychain.delete(.personalAPIKey)
                                hasSavedKey = false
                                model.dataChanged()
                            }
                        }
                    }
                }
            }
            ModelPicker(service: .personalAPI, model: $settings.personalModel, prompt: "例如 gpt-4o-mini",
                        canFetch: hasSavedKey && !settings.personalBaseURL.isEmpty)
            ConnectionRow(busy: busy, message: message, failed: failed, enabled: true) {
                Task { await test() }
            }
        } header: {
            if showsHeader { Text("个人 API") }
        } footer: {
            Footnote(text: "支持 OpenAI 兼容的 Chat Completions 接口。API Key 只保存在本机钥匙串，并且只发送到上面的服务地址。")
        }
        .onAppear { hasSavedKey = model.keychain.contains(.personalAPIKey) }
    }

    private func save() {
        guard !apiKey.isEmpty else { return }
        if model.keychain.write(apiKey, for: .personalAPIKey) {
            apiKey = ""
            hasSavedKey = true
            message = "Key 已保存到钥匙串。"
            failed = false
            model.dataChanged()
        } else {
            message = "保存到钥匙串失败。"
            failed = true
        }
    }

    private func test() async {
        if !apiKey.isEmpty { save() }
        busy = true
        defer { busy = false }
        (message, failed) = await model.testConnection()
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
    @State private var signInError: String?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Section {
            LabeledContent("账号") {
                HStack(spacing: 10) {
                    if let account = appModel.accounts[service] {
                        let name = account.email ?? "已登录"
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Theme.accent, in: Circle())
                            .accessibilityHidden(true)
                        Text(name).textSelection(.enabled)
                        Button("退出登录") {
                            message = nil
                            Task { await appModel.signOut(service) }
                        }
                    } else if signInTask != nil {
                        ProgressView().controlSize(.small)
                        Text("请在浏览器中完成授权…").foregroundStyle(.secondary)
                        Button("取消") { signInTask?.cancel() }
                    } else if appModel.auth(for: service)?.provider.isClientConfigured == false {
                        Text("此版本未配置 OAuth 客户端，见 README").foregroundStyle(.secondary)
                    } else {
                        Button("使用浏览器登录…") { signIn() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                }
            }
            if let signInError {
                Text(signInError).font(.callout).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            ModelPicker(service: service, model: $model, prompt: service.suggestedModels.first ?? "",
                        canFetch: appModel.accounts[service] != nil)
            ConnectionRow(busy: busy, message: message, failed: failed, enabled: appModel.accounts[service] != nil) {
                Task {
                    busy = true
                    (message, failed) = await appModel.testConnection()
                    busy = false
                }
            }
        } header: {
            Text(service.shortName)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Footnote(text: note)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Frees the callback port when the form goes away mid sign-in.
        .onDisappear { signInTask?.cancel() }
    }

    private func signIn() {
        signInError = nil
        message = nil
        signInTask = Task {
            do {
                try await appModel.signIn(service)
            } catch TranslationError.cancelled {
                // Cancelled by the user or the form closing.
            } catch {
                signInError = (error as? TranslationError)?.userMessage ?? error.localizedDescription
            }
            signInTask = nil
        }
    }
}

/// Result of the last connection test and the button that runs it.
private struct ConnectionRow: View {
    let busy: Bool
    let message: String?
    let failed: Bool
    let enabled: Bool
    let test: () -> Void

    var body: some View {
        LabeledContent("连接") {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let message {
                    Label(message, systemImage: failed ? "xmark.circle.fill" : "checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(failed ? Theme.danger : Theme.success)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("尚未测试").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button("测试连接", action: test).disabled(busy || !enabled)
            }
        }
    }
}

/// Model name field with a menu of the models the service offers. The list is
/// fetched once credentials are available (on open, after saving a key or
/// signing in); until then the suggested names are offered. Names can still be
/// typed by hand.
private struct ModelPicker: View {
    let service: TranslationService
    @Binding var model: String
    let prompt: String
    let canFetch: Bool

    @EnvironmentObject private var appModel: AppModel
    @State private var loading = false
    @State private var error: String?

    private var fetched: [RemoteModel]? { appModel.remoteModels[service] }
    private var choices: [RemoteModel] { fetched ?? service.suggestedModels.map { RemoteModel(id: $0) } }

    var body: some View {
        LabeledContent("模型") {
            HStack(spacing: 6) {
                TextField("模型", text: $model, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Menu {
                    ForEach(choices) { choice in
                        Button { model = choice.id } label: {
                            if choice.id == model {
                                Label(choice.displayName ?? choice.id, systemImage: "checkmark")
                            } else {
                                Text(choice.displayName ?? choice.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(choices.isEmpty)
                .help("选择模型")
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await fetch() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .help("从服务器刷新模型列表")
                        .accessibilityLabel("刷新模型列表")
                        .disabled(!canFetch)
                }
            }
        }
        .task(id: canFetch) {
            if canFetch && fetched == nil { await fetch() }
        }
        if let error {
            Text("获取模型列表失败：\(error)").font(.caption).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        } else if let fetched, !model.isEmpty, !fetched.contains(where: { $0.id == model }) {
            Text("当前模型不在服务器返回的列表中，可能无法使用。").font(.caption).foregroundStyle(Theme.warning)
        }
    }

    private func fetch() async {
        loading = true
        defer { loading = false }
        do {
            try await appModel.fetchModels(for: service)
            error = nil
        } catch TranslationError.cancelled {
            // The form went away mid-request.
        } catch {
            self.error = (error as? TranslationError)?.userMessage ?? error.localizedDescription
        }
    }
}
