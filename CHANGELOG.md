# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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

[Unreleased]: https://github.com/carter-ya/clipboard/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/carter-ya/clipboard/releases/tag/v1.0.0

