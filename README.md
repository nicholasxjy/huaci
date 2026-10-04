# 划词（Huaci）

macOS 菜单栏划词翻译：在任意应用中选中文字，按快捷键（默认 `⌃⌥T`），在鼠标附近查看翻译。单词显示释义、音标、词性和例句，句子与段落显示译文。翻译通过你自己配置的 OpenAI 兼容 API 完成（服务地址、API Key、模型）。

需求与实现方案见 [docs/mvp-plan.md](docs/mvp-plan.md)，跨应用实测清单见 [docs/compatibility.md](docs/compatibility.md)。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/HuaciCore` | 取词（辅助功能 + 剪贴板回退与恢复）、语言判断、提示词与结果解析、OpenAI 兼容客户端、SQLite 历史/生词、Keychain |
| `Sources/Huaci` | 菜单栏应用：全局快捷键、翻译浮窗、设置、首次引导、历史与生词本 |
| `Tests/HuaciCoreTests` | 单元测试 |
| `Resources` | App 图标（1024px PNG 预览与包含标准 / Retina 尺寸的 ICNS） |
| `scripts` | 打包脚本与图标生成脚本 |

## 客户端

要求 macOS 13+、Xcode（命令行工具中的 Swift 也能编译，但测试与通用二进制需要 Xcode）。如果 `xcode-select` 指向 CommandLineTools，脚本会自动使用 `/Applications/Xcode.app`。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                       # 单元测试
./scripts/build-app.sh           # 生成 build/Huaci.app（ad-hoc 签名）
open build/Huaci.app
```

App 图标以选中的英文字母和中文翻译气泡表达“划词翻译”。打包时会自动复制 `Resources/AppIcon.icns` 并设置应用图标；修改矢量绘图源 `scripts/generate-icons.swift` 后，可重新生成全部尺寸，再打包：

```sh
swift scripts/generate-icons.swift
./scripts/build-app.sh
```

打包参数（环境变量）：

- `VERSION`：应用版本号，默认 `0.0.2`。
- `UNIVERSAL=1`：同时构建 arm64 与 x86_64。
- `SIGN_IDENTITY`：Developer ID 证书名称，启用 Hardened Runtime 签名；不设置时为 ad-hoc 签名。
- `NOTARY_PROFILE`：`xcrun notarytool store-credentials` 保存的配置名；设置后自动公证并装订。

首次启动会打开引导：填写 API 服务地址、Key 和模型（可点“测试连接”）→ 开启“隐私与安全性 › 辅助功能”权限 → 开始使用。API Key 只保存在本机钥匙串，只发送到你填写的服务地址。

注意：

- ad-hoc 签名每次重新构建签名都会变化，需要在系统设置中把“划词”的辅助功能权限关掉再打开（或移除后重新添加）；钥匙串也可能再次询问访问权限。使用 Developer ID 签名后不会出现这个问题。
- 取词优先读取辅助功能选区，不改动剪贴板；读不到时发送 ⌘C，只在剪贴板确实发生变化时使用复制结果，并且仅当剪贴板仍是这次复制的内容时恢复原内容（包括多条目、多类型数据）。
- 历史与生词保存在 `~/Library/Application Support/Huaci/huaci.sqlite`；API Key 保存在登录钥匙串（服务名 `app.huaci.Huaci`）。

## 尚需人工验证

自动化测试覆盖了取词状态机（使用模拟剪贴板与模拟系统环境）、浮窗定位、请求先后顺序、存储和 OpenAI 兼容客户端。以下内容依赖真实系统环境，需要按 [docs/compatibility.md](docs/compatibility.md) 实测：

- 各目标应用中的辅助功能取词与 ⌘C 回退、剪贴板恢复；
- 全局快捷键冲突提示、浮窗焦点与 Esc/点击外部关闭、多显示器；
- 实际所用模型的输出质量（建议用代表性单词、句子和长段落评测后选定模型）；
- 签名、公证与朋友设备上的安装流程。
