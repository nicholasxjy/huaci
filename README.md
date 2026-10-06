# 划词（Huaci）

macOS 菜单栏划词翻译：在任意应用中选中文字，按快捷键（默认 `⌃⌥T`），在鼠标附近查看翻译。单词显示释义、音标和例句，句子与段落显示译文。

## 翻译服务

| 服务 | 认证方式 | 说明 |
| --- | --- | --- |
| 个人 API | 服务地址 + API Key + 模型 | 任意 OpenAI 兼容的 Chat Completions 接口 |
| ChatGPT 账号 | 浏览器 OAuth 登录 | 使用 ChatGPT 订阅额度 |
| Antigravity | 浏览器 Google OAuth 登录 | 使用 Antigravity 的模型额度 |

ChatGPT 与 Antigravity 都不是公开 API，接口随时可能变化；**Antigravity 方式可能违反 Google 服务条款，已有用户报告账号被限制或封禁**，请自行评估风险。

## 构建

要求 macOS 13+ 与 Xcode。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                  # 单元测试
./scripts/build-app.sh      # 生成 build/Huaci.app
open build/Huaci.app
```

打包参数（环境变量）：`VERSION`、`UNIVERSAL=1`（通用二进制）、`SIGN_IDENTITY`（Developer ID 签名）、`NOTARY_PROFILE`（公证）。Antigravity 登录需要 OAuth 客户端：复制 `secrets.env.example` 为 `secrets.env` 并填写。

## 使用须知

- 首次启动按引导配置翻译服务，并开启“隐私与安全性 › 辅助功能”权限。
- ad-hoc 签名每次重新构建都会变化，需要在系统设置中重新勾选辅助功能权限。
- API Key 与 OAuth 令牌只保存在本机钥匙串；历史、生词本与翻译缓存保存在 `~/Library/Application Support/Huaci/huaci.sqlite`。

需求与实现方案见 [docs/mvp-plan.md](docs/mvp-plan.md)，跨应用实测清单见 [docs/compatibility.md](docs/compatibility.md)。
