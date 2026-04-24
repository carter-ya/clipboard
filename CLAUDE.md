# Clipboard

macOS 剪贴板历史应用。项目规格的权威来源是 [`harness.json`](./harness.json) —— 任何改动前先读。

## 快速上手

```bash
just gen     # 用 XcodeGen 生成 .xcodeproj
just build   # 冷编译
just run     # 启动 App（菜单栏会出现图标）
just test    # 运行 Core 的单元测试
just lint    # swift-format 检查
just logs    # 流式查看 os.Logger 输出（subsystem com.clipboard.app）
just reset   # 清除本地历史数据（~/Library/Application Support/Clipboard）
just clean   # 清理 build 与生成的 .xcodeproj
```

## 结构

- `Core/` —— `ClipboardCore` Swift Package：所有业务逻辑，可独立测试
- `App/` —— macOS App target：菜单栏外壳 + 装配层，不含业务逻辑
- `project.yml` —— XcodeGen 源；`.xcodeproj` 每次 `just gen` 生成，**不提交**
- `harness.json` —— 项目单一事实源，任何偏离都要在同一次提交中更新
- `docs/release-notes/<ver>/<lang>.html` —— Sparkle 弹窗里的多语言 release notes，发版前 7 份（en / zh-Hans / zh-Hant / ja / ko / de / es）必须齐全；`just release-notes-check VERSION` 本地预演，CI 也会卡

## 约定摘要

完整约定见 `harness.json` 的 `harness.conventions` / `guardrails`。要点：

- 业务逻辑留在 `ClipboardCore`；UI 层通过协议依赖 Core，装配点在 `App/AppWiring.swift`
- 日志统一走 `os.Logger`（subsystem `com.clipboard.app`）；禁止 `print()`
- 不合成键盘事件（不用 CGEvent / AppleScript / Accessibility）——选中条目只写剪贴板，用户自行 `Cmd+V`
- 不启用 App Sandbox；不上 Mac App Store
- 敏感条目仅驻留内存、绝不落盘（JSON / blobs/ / 导出 / 日志正文均不明文出现）
- 三队列分工：`monitor_queue`（轮询与过滤）/ `store_queue`（哈希与持久化）/ `main_queue`（UI）

## Slice 节奏

见 `harness.json` 的 `slices[]` 与 `slice_rhythm`。每个 slice 以绿色、可运行、可提交的状态结束。
