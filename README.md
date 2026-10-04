# 划词（Huaci）

macOS 菜单栏划词翻译：在任意应用中选中文字，按快捷键（默认 `⌃⌥T`），在鼠标附近查看翻译。单词显示释义、音标、词性和例句，句子与段落显示译文。翻译服务可在以下三种之间切换（设置 › 翻译服务，或菜单栏 › 翻译服务）：

| 服务 | 认证方式 | 说明 |
| --- | --- | --- |
| 个人 API | 服务地址 + API Key + 模型 | 任意 OpenAI 兼容的 Chat Completions 接口 |
| ChatGPT 账号 | 浏览器 OAuth 登录（与 Codex CLI 的 “Sign in with ChatGPT” 相同） | 使用 ChatGPT 订阅额度，请求 `chatgpt.com/backend-api/codex/responses`；回调端口 1455 |
| Antigravity | 浏览器 Google OAuth 登录（Antigravity 的客户端） | 使用 Antigravity 的模型额度，请求 Cloud Code Assist `v1internal:streamGenerateContent`；回调端口 51121 |

各服务的配置与登录状态分别保存，切换时无需重新登录。ChatGPT 与 Antigravity 都不是公开 API，接口随时可能变化；**Antigravity 方式可能违反 Google 服务条款，已有用户报告账号被限制或封禁**，请自行评估风险。

需求与实现方案见 [docs/mvp-plan.md](docs/mvp-plan.md)，跨应用实测清单见 [docs/compatibility.md](docs/compatibility.md)。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/HuaciCore` | 取词（辅助功能 + 剪贴板回退与恢复）、语言判断、提示词与结果解析、OpenAI 兼容 / ChatGPT / Antigravity 客户端、OAuth（PKCE + 本机回调）、SQLite 历史/生词、Keychain |
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

- `VERSION`：应用版本号，默认 `0.0.5`。
- `UNIVERSAL=1`：同时构建 arm64 与 x86_64。
- `SIGN_IDENTITY`：Developer ID 证书名称，启用 Hardened Runtime 签名；不设置时为 ad-hoc 签名。
- `NOTARY_PROFILE`：`xcrun notarytool store-credentials` 保存的配置名；设置后自动公证并装订。
- `ANTIGRAVITY_CLIENT_ID`、`ANTIGRAVITY_CLIENT_SECRET`：Antigravity 的 Google OAuth 客户端，打包时写入 Info.plist。它们不提交到仓库：复制 `secrets.env.example` 为 `secrets.env`（已在 `.gitignore` 中）并填写，脚本会自动读取；也可以直接设置环境变量（`swift run` 时同样读取环境变量）。未设置时 Antigravity 无法登录，其他服务不受影响。

首次启动会打开引导：选择翻译服务并完成配置（个人 API 填写服务地址、Key 和模型；ChatGPT / Antigravity 点“使用浏览器登录”），可点“测试连接” → 开启“隐私与安全性 › 辅助功能”权限 → 开始使用。API Key 与 OAuth 令牌只保存在本机钥匙串，只发送到对应服务。

注意：

- ad-hoc 签名每次重新构建签名都会变化，需要在系统设置中把“划词”的辅助功能权限关掉再打开（或移除后重新添加）；钥匙串也可能再次询问访问权限。使用 Developer ID 签名后不会出现这个问题。
- 取词优先读取辅助功能选区，不改动剪贴板；读不到时发送 ⌘C，只在剪贴板确实发生变化时使用复制结果，并且仅当剪贴板仍是这次复制的内容时恢复原内容（包括多条目、多类型数据）。
- 网络代理：OAuth 令牌请求和所有翻译请求都使用系统代理设置（系统设置 › 网络 › 代理，包括自动代理配置）。浏览器登录页由浏览器自身的代理设置决定；登录回调访问的是本机 `localhost`，不经过代理。
- 历史与生词保存在 `~/Library/Application Support/Huaci/huaci.sqlite`；API Key 与 OAuth 令牌保存在登录钥匙串（服务名 `app.huaci.Huaci`，账户名分别为 `personal-api-key`、`chatgpt-oauth`、`antigravity-oauth`）。

## 尚需人工验证

自动化测试覆盖了取词状态机（使用模拟剪贴板与模拟系统环境）、浮窗定位、请求先后顺序、存储、OpenAI 兼容 / ChatGPT / Antigravity 客户端，以及经过真实本机回调服务器的 OAuth 登录与令牌刷新。以下内容依赖真实系统环境，需要按 [docs/compatibility.md](docs/compatibility.md) 实测：

- 各目标应用中的辅助功能取词与 ⌘C 回退、剪贴板恢复；
- 全局快捷键冲突提示、浮窗焦点与 Esc/点击外部关闭、多显示器；
- 实际所用模型的输出质量（建议用代表性单词、句子和长段落评测后选定模型）；
- ChatGPT 与 Antigravity 的真实登录和翻译请求（测试只覆盖模拟的令牌端点与接口响应；登录页已确认能正常打开）；
- 签名、公证与朋友设备上的安装流程。
