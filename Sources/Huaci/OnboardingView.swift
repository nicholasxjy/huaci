import Combine
import HuaciCore
import SwiftUI

/// First launch: configure the API, grant Accessibility, learn the shortcut.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var step = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(["1. 配置翻译 API", "2. 开启辅助功能权限", "3. 开始使用"][step]).font(.title2.weight(.semibold))
            Group {
                switch step {
                case 0: Form { ServiceConfigurationView() }.formStyle(.grouped)
                case 1: permissionStep
                default: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 { Button("上一步") { step -= 1 } }
                Spacer()
                if step < 2 {
                    Button("下一步") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("完成") {
                        settings.onboardingCompleted = true
                        WindowRouter.shared.close(id: "onboarding")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .onReceive(timer) { _ in model.refreshAccessibility() }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("划词需要 macOS 的“辅助功能”权限，用于：")
            VStack(alignment: .leading, spacing: 6) {
                Label("读取其他应用中当前选中的文字", systemImage: "text.cursor")
                Label("读取不到时临时发送 ⌘C 复制选区，取词后立即恢复你原来的剪贴板", systemImage: "doc.on.clipboard")
            }
            .padding(.leading, 4)
            Text("划词不会读取选区之外的内容。原文只发送给你配置的 API 服务地址。")
                .foregroundStyle(.secondary)
            HStack {
                if model.accessibilityTrusted {
                    Label("已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("打开系统设置") {
                        SystemSelectionEnvironment.requestAccessibilityPrompt()
                        SystemSelectionEnvironment.openAccessibilitySettings()
                    }
                    Text("在“隐私与安全性 › 辅助功能”中打开“划词”。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在任意应用中选中文字，然后按：")
            Text(settings.shortcut.displayString).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("翻译会显示在鼠标附近；点击窗口外部或按 Esc 关闭。单词可以收藏到生词本。")
            Text("快捷键、目标语言和 API 配置都可以随时在菜单栏图标 › 设置中修改。")
                .foregroundStyle(.secondary)
            if let error = model.hotKeyError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                ShortcutRecorder()
            }
        }
    }
}
