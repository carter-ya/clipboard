# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.5] - 2026-06-26

### 新增

- 现在为 Apple Silicon 与 Intel 分别提供独立的单架构 DMG（`Clipboard-<ver>-arm64.dmg` / `Clipboard-<ver>-x86_64.dmg`），Intel Mac 终于可装可用。每个下载只含本机架构，体积更轻；自动更新按架构走各自的 Sparkle feed，已安装的老版本会无缝拿到对应架构的更新。

## [1.0.4] - 2026-06-26

### 修复

- 全局快捷键现在能稳定唤出窗口：改用 Carbon `RegisterEventHotKey` 自管注册，修复应用闲置后首次按键偶尔无响应的问题。
- 偏好设置 → Retention 的「条数上限」与「最大体积」输入框现在整框可点击：让输入控件填满外框、改用 `onContinuousHover` 取光标，修复了「只有点右侧数字才生效」「悬浮光标忽闪」「点击误选中全部」三个问题。
- 偏好设置窗口现在记住上次位置：不再每次打开都自动居中或被推到右上角（旧逻辑替换内容视图时窗口瞬间塌成 0 高、被 AppKit 左上锚定逐次上移），改为常驻 hosting controller + frame autosave。

## [1.0.3] - 2026-04-25

### 新增

- 可选的 OpenAI 兼容远端 AI（OpenAI / Ollama / vLLM / OpenRouter / DeepSeek 等）作为文本与图像 summary 引擎，失败自动回退到本地 FM / NL / Vision
- 偏好设置 → AI → 「Remote AI (OpenAI-compatible)」配置区，含 Base URL / Model / API Key / 测试连接 按钮

### 修复

- API Key 现在选填（本地模型如 Ollama 无需配置）。
- Test connection 在 HTTP 404 时给出可操作提示；其它 4xx/5xx (含 401/403) 展示远端返回的错误信息（sanitised，仅 UI，不写日志）。
- Remote AI 输入框（Base URL / Model / API Key）文字与占位符正确左对齐。
- 禁用 Remote AI 不会删除已保存的 API Key；如需删除请使用 Remove 按钮。注：更换 Base URL 时旧端点对应的 Keychain 项保留（按设计，每端点独立 account）。
- 支持远端 AI 摘要文件（PDF / 常见文本扩展名），FM 不可用的设备也能用了。
- 剥离 reasoning 模型（Qwen3-think / DeepSeek-R1 等）输出中的 `<think>...</think>` 思考块。
- 摘要输出语言跟随用户偏好（系统语言或 Preferences → 语言）。
- AI 摘要生成时显示进度，失败时给出重试按钮。
- 后台摘要请求**移除 `max_tokens` 限制**，让模型按 EOS 自停。原本 80 → 400 → 1200 → 4000 一路调高都是和 reasoning 模型 think 块大小赛跑，不必要——system prompt 已要求"单句 ≤160 字"，client 端 200 字 prefix 截断 + 64 KB 响应体上限已足够兜底。Test connection 探测保留 `max_tokens=4` 以维持快速健康检查。
- 修复摘要不跟随用户语言偏好的问题。原因是 system prompt 末尾的 "Always reply in <Language>." 在小模型（3B 类）上经常被忽略；改为：(1) 把语言指令前置到 system prompt 开头并加 "All output must be in X regardless of the input's language."；(2) user message 也改用目标语言写（如简中："请用简体中文总结以下内容（无论输入是何种语言，回答必须使用简体中文）："）。中等长度及以上的输入现在能稳定按用户偏好语言产出。短纯 ASCII 输入（如 IP、路径）仍可能受具体模型能力限制——属于 reasoning 模型对无语义短输入的处理能力问题，建议改用非 reasoning 模型或长一点的输入。
- 未覆盖的语言（fr / ru / it / pt 等 UI 7 语之外）现在通过 Apple 的 Locale 服务动态拿英文名（如 `fr` → "French"）注入 system prompt，覆盖 ~150 种语言；user wrapper 仍退到英文（无目标语言原生句子），但 system 指令足以让正经能力的模型产出对应语言。
- 默认远端超时从 20 秒提到 60 秒，适配 Ollama 本地 reasoning 模型常见的 20–50 秒响应时间（旧版 20 秒会被当成"未配置"自动跟进新默认）。
- system prompt 增加"不要包含思考过程；过短输入直接回显原文"指令，提升 reasoning 模型与极短剪贴板内容的输出质量。
- 修复 progress 事件管道：`SummaryCoordinator.start()` 不再误关 progress AsyncStream 的 continuation，VM 现在能正常收到 generating / finished / failed 事件，预览面板的进度提示真实可见。
- 修复 reasoning 模型摘要被截断成 `` `) without outputting content. ... `` 之类乱码：strip 策略改为只剥离开头的 reasoning 块且采用贪婪 LAST `</think>`，保留正文里对 `<think>` 的字面引用不被误删。
- 修复 Finder 复制 PDF / docx 等文档时被误判为图片、Vision 把 PDF 图标 OCR 成 "diskette, media" 的 bug：`ClipKind.infer` 看到 image-payload + file-url 同时存在时，按文件扩展名判断（非图片扩展名走 file 路径，图片扩展名维持 image，Telegram / Messages 用 case 不受影响）。

### 隐私

- API Key 存于 Keychain（per-endpoint）；敏感与隐藏类型剪贴板永不外发；7 语本地化

## [1.0.2] - 2026-04-24

### 新增

- Sparkle 弹窗有了多语言 release notes：`docs/release-notes/<version>/<lang>.html` 为每个版本维护 7 份轻量 HTML（en / zh-Hans / zh-Hant / ja / ko / de / es），`docs/appcast.xml` 通过 `<sparkle:releaseNotesLink xml:lang="…">` 让 Sparkle 按系统语言自动挑对

### 修复

- 偏好设置 → Updates 区块的标题、『检查更新…』按钮、未配置提示现在会跟随语言；7 份 `Localizable.strings` 都补上了 `Updates` / `Check for Updates…` / `Automatic updates are not configured in this build.` 三个 key

### 优化

- 历史面板底部的快捷键 footer 移除：同一份信息已经在 Preferences → Shortcuts 分页里完整列出，面板整体高度从 520pt 收到 491pt，列表区域自然多显示 1~2 条
- 偏好设置新增独立的 **AI** 分页：原 General 底部的『AI Summaries』开关组（master + 图片 / 文本 / 文件 三个子开关 + 本机能力说明）整体上移为顶层 Tab，与 General / Shortcuts / Privacy / Data 同级，AI 配置一步直达

### 分发

- 新增一键安装脚本 `docs/install.sh`（`curl -fsSL https://carter-ya.github.io/clipboard/install.sh | bash`）：拉最新 DMG、校验 SHA-256、退出正在运行的 Clipboard、安装到 `/Applications/`、清 Gatekeeper 隔离标记

### 文档

- `README.md` 默认语言改为英文（沿 GitHub 惯例）；中文版迁到 `README.zh-Hans.md`，并新增 `README.zh-Hant.md` / `README.ja.md` / `README.ko.md` / `README.de.md` / `README.es.md`，覆盖 App 已支持的全部 7 种 locale；每份 README 顶部加语言切换行

## [1.0.1] - 2026-04-24

### 分发

- DMG 改版：安装窗口带背景图和 `/Applications` 快捷方式，打开后直接拖入即可；无功能变更

## [1.0.0] - 2026-04-24

首次公开发布。

### 新增

- 菜单栏常驻的剪贴板历史面板，全局快捷键召唤
- 文本 / 富文本 / 图片 / 文件四种条目类型，带缩略图预览
- 按 kind 过滤 + 全文搜索（图片 OCR 结果也可搜）
- 敏感内容识别：密码、金融卡号等条目仅驻留内存，不落盘 / 导出 / 日志
- 按源应用屏蔽（bundle ID 黑名单）
- AI 摘要：Vision OCR + NaturalLanguage 实体识别；macOS 26+ 可选用 Foundation Models
- 多语言界面：English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Deutsch / Español
- Pin 条目不被容量上限淘汰
- 历史数据导入 / 导出为 zip
- Sparkle 自动更新（EdDSA 校验，独立于 Apple 签名）
- 面板键盘快捷键：`⌘⇧[` / `⌘⇧]` 循环切换 kind tab，`⌘1`–`⌘6` 直接选中 kind
- 偏好设置新增 **Shortcuts** 分页：集中展示全局快捷键与面板内快捷键

### 优化

- 剪贴板轮询间隔收紧至约 80ms，遗漏窗口缩小约 4×

### 分发

- 直接分发未签名 DMG；首次安装需用户 `xattr -cr` 解除 Gatekeeper 隔离标记
- 不上 Mac App Store、不启用 App Sandbox

[Unreleased]: https://github.com/carter-ya/clipboard/compare/v1.0.5...HEAD
[1.0.5]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.5
[1.0.4]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.4
[1.0.3]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.3
[1.0.2]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.2
[1.0.1]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.1
[1.0.0]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.0

