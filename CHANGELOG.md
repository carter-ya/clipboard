# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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

[Unreleased]: https://github.com/carter-ya/clipboard/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.2
[1.0.1]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.1
[1.0.0]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.0

