import AppKit
import Combine
import HuaciCore
import SwiftUI

/// First launch: choose a translation service, grant Accessibility, try a lookup.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var step = 0
    /// Accessibility state when the permission step appeared; it advances on
    /// its own only when access is granted while the step is showing.
    @State private var trustedOnArrival = false
    /// Popup results seen before the practice step; a newer one means it worked.
    @State private var practiceBaseline = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(step: step, count: 3)
                .frame(height: 44)
            ScrollView {
                Group {
                    switch step {
                    case 0: serviceStep
                    case 1: permissionStep
                    default: practiceStep
                    }
                }
                .padding(EdgeInsets(top: 20, leading: 56, bottom: 24, trailing: 56))
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(timer) { _ in
            model.refreshAccessibility()
            if step == 1 && !trustedOnArrival && model.accessibilityTrusted { step = 2 }
        }
        .onChange(of: step) { newStep in
            if newStep == 1 { trustedOnArrival = model.accessibilityTrusted }
            if newStep == 2 { practiceBaseline = model.popupResultCount }
        }
    }

    // MARK: Steps

    private var serviceStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                Text("欢迎使用划词").font(.system(size: 24, weight: .bold)).padding(.top, 4)
                Text("在任意应用中选中文字，按下快捷键，翻译就出现在鼠标旁边。\n先选择一个翻译服务。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            VStack(spacing: 8) {
                ForEach([TranslationService.chatGPT, .personalAPI, .antigravity]) { service in
                    OnboardingServiceRow(service: service)
                }
            }
        }
    }

    private var permissionStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("允许划词读取选中的文字").font(.system(size: 24, weight: .bold)).padding(.top, 8)
                Text("在「系统设置 › 隐私与安全性 › 辅助功能」中打开划词。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("辅助功能").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    settingsRow(icon: AnyView(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.6))), name: "其他应用",
                                on: false, highlighted: false)
                    Divider()
                    settingsRow(icon: AnyView(Image(nsImage: NSApp.applicationIconImage).resizable()), name: "划词",
                                on: model.accessibilityTrusted, highlighted: true)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            }
            .padding(22)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Label("只读取你选中的那段文字，不读屏幕上的其他内容。", systemImage: "character.cursor.ibeam")
                Label("个别应用读不到时会临时复制选区，随后恢复你原来的剪贴板。", systemImage: "doc.on.clipboard")
            }
            .font(.system(size: 13))
            .labelStyle(AccentIconLabelStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsRow(icon: AnyView, name: String, on: Bool, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            icon.frame(width: 24, height: 24)
            Text(name).font(.system(size: 13, weight: highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? .primary : .secondary)
            Spacer()
            Capsule()
                .fill(on ? Theme.accent : Color.primary.opacity(0.12))
                .frame(width: 38, height: 22)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 0.5, y: 0.5).padding(2)
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(highlighted ? Theme.accentSoft : .clear)
        .overlay(highlighted ? RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2) : nil)
    }

    private var practiceStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("试一试").font(.system(size: 24, weight: .bold)).padding(.top, 8)
                (Text("双击下面的 ") + Text("beginner").bold() + Text(" 选中它，然后按："))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            KeyCaps(shortcut: settings.shortcut, large: true)
            PracticeTextView(text: "Every expert was once a beginner.")
                .frame(height: 34)
                .padding(.vertical, 28)
                .padding(.horizontal, 24)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if model.hotKeyError != nil {
                VStack(spacing: 8) {
                    Text("这个快捷键现在不可用，点击下面换一个：").foregroundStyle(Theme.warning)
                    ShortcutRecorder()
                }
            } else if model.popupResultCount > practiceBaseline {
                Label("成功了。划词会一直待在菜单栏里。", systemImage: "checkmark")
                    .foregroundStyle(Theme.success)
            } else {
                Text("翻译会出现在鼠标旁边；点击外部或按 Esc 关闭。").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            switch step {
            case 0:
                Button("稍后设置") { step = 1 }.buttonStyle(ActionButtonStyle(tint: .secondary))
                Spacer()
                primary("继续") { step = 1 }
            case 1:
                Button("上一步") { step = 0 }.buttonStyle(ActionButtonStyle(tint: .secondary))
                Spacer()
                if model.accessibilityTrusted {
                    Label("已开启", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.success)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("开启后会自动进入下一步").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.accessibilityTrusted {
                    primary("继续") { step = 2 }
                } else {
                    primary("打开系统设置") {
                        SystemSelectionEnvironment.requestAccessibilityPrompt()
                        SystemSelectionEnvironment.openAccessibilitySettings()
                    }
                }
            default:
                Button("更改快捷键…") { WindowRouter.shared.showSettings(.general) }.buttonStyle(ActionButtonStyle(tint: .secondary))
                Spacer()
                primary("开始使用") {
                    settings.onboardingCompleted = true
                    WindowRouter.shared.close(id: "onboarding")
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .overlay(alignment: .top) { Divider() }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).padding(.horizontal, 8) }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

private struct StepIndicator: View {
    let step: Int
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(index <= step ? Theme.accent : Color.primary.opacity(0.12)).frame(width: 24, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step + 1) 步，共 \(count) 步")
    }
}

private struct AccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.foregroundStyle(Theme.accent).frame(width: 18)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Radio row for a service; the selected one expands to sign in or configure.
private struct OnboardingServiceRow: View {
    let service: TranslationService
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var signInTask: Task<Void, Never>?
    @State private var signInError: String?

    private var selected: Bool { settings.activeService == service }

    private var detail: String {
        switch service {
        case .chatGPT: return "用 ChatGPT 订阅额度，浏览器登录即可"
        case .personalAPI: return "填写服务地址、API Key 和模型，兼容 OpenAI 接口"
        case .antigravity: return "Google 账号额度 · 非官方接入，有封号风险"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                settings.activeService = service
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .strokeBorder(selected ? Theme.accent : Color.secondary.opacity(0.6), lineWidth: selected ? 5 : 1.5)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.shortName).font(.system(size: 14, weight: .semibold))
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if service == .chatGPT {
                        Text("推荐").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected {
                Group {
                    if service.usesOAuth { oauthStatus } else { personalAPI }
                }
                .padding(.leading, 30)
            }
        }
        .padding(selected ? 13 : 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
        )
        .onDisappear { signInTask?.cancel() }
    }

    @ViewBuilder
    private var oauthStatus: some View {
        HStack(spacing: 10) {
            if let account = model.accounts[service] {
                Label("已登录 \(account.email ?? "")", systemImage: "checkmark").foregroundStyle(Theme.success)
            } else if signInTask != nil {
                ProgressView().controlSize(.small)
                Text("请在浏览器中完成授权…").foregroundStyle(.secondary)
                Button("取消") { signInTask?.cancel() }
            } else if model.auth(for: service)?.provider.isClientConfigured == false {
                Text("此版本未配置 OAuth 客户端，见 README").foregroundStyle(.secondary)
            } else {
                Button("使用浏览器登录…", action: signIn)
            }
        }
        .font(.system(size: 13))
        if let signInError {
            Text(signInError).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var personalAPI: some View {
        Form { PersonalAPIForm(showsHeader: false) }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 320)
            .padding(.horizontal, -20)
    }

    private func signIn() {
        signInError = nil
        signInTask = Task {
            do {
                try await model.signIn(service)
            } catch TranslationError.cancelled {
                // Cancelled by the user or the window closing.
            } catch {
                signInError = (error as? TranslationError)?.userMessage ?? error.localizedDescription
            }
            signInTask = nil
        }
    }
}

/// Selectable, read-only text; the practice lookup reads its selection
/// directly (the app's own text view needs no Accessibility access).
private struct PracticeTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        let base = NSFont.systemFont(ofSize: 20)
        view.font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 20) } ?? base
        view.textColor = .labelColor
        view.alignment = .center
        view.string = text
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {}
}
