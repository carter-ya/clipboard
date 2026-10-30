# Clipboard

macOS 剪贴板历史应用。项目规格的权威来源是 [`harness.json`](./harness.json) —— 任何改动前先读。

## 快速上手

```bash
just gen     # 用 XcodeGen 生成 .xcodeproj
just build   # 冷编译
just run     # 启动 App（菜单栏会出现图标）
just test    # 运行 Core 的单元测试
just test-windows # 在桌面会话运行原生窗口回归（仅合成测试内容）
just test-window-runner # 无界面验证测试并发隔离／中断清理
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
- 界面最低兼容 macOS 13；macOS 26+ 两窗统一使用单层 regular 原生磨砂玻璃，旧系统回退 popover / behindWindow。设置玻璃贯穿标题栏与正文，正文约束到系统 contentLayoutGuide，不手工写标题栏高度。禁止整块实色背景遮住材质；辅助功能可回退实色。正常外观不叠加窗口描边，仅提高对比度时保留辅助轮廓。历史面板保持无标题栏的 nonactivating panel，不为淡化边缘改成 titled/fullSizeContentView 或改变 safe area；S89 外框试验已因用户报告输入回归撤回。macOS 26+ 只将历史玻璃向外扩展 1pt 并用圆角 viewport 裁掉细边，前景反向补偿、保持坐标和尺寸不变；隐藏时连同材质释放裁切层。隐藏窗口释放界面、材质、约束和显示设置监听；不添加逐行玻璃、循环动画或 UI 轮询。
- 设置交接到历史面板时，先卸载设置内容，等历史面板关闭后再恢复 accessory；返回设置时取消这次恢复，避免切换后台状态撤销搜索焦点。保留系统输入框及其输入法行为；面板显示完成或成为 key 时，在布局后明确设置搜索框为第一响应者，已在编辑时不重复设置。搜索面板 becomesKeyOnlyIfNeeded=false，确保设置交接后无需先点击控件才能接管键盘。不添加延迟抢焦点或重试轮询。焦点验收必须区分程序内 insertText 与真实快捷键后的键盘交接，不能只凭前者宣称后者通过。

- 新会话在显示前完成屏幕尺寸、列表重置、搜索框布局和 initialFirstResponder 设置；自动聚焦由 AppKit 窗口显示／成为 key 的路径负责，不再叠加 SwiftUI onAppear 聚焦。保留 FocusState 的 Cmd+F／清空操作。主面板禁用默认出现动画，不添加延迟聚焦重试，保留玻璃材质。

- “通用 → 外观”提供跟随系统／浅色／深色，默认跟随系统。外观选择器使用固定原生段宽及独立布局容器，避免重复点击、切页或主题变化改变长度；点击已选设置页不重复发布导航变化。偏好保存后直接设置 NSApplication.appearance，启动时提前恢复；不重启 Monitor、不增加轮询。辅助功能实色背景在 effectiveAppearance 改变时刷新颜色。

- 偏好设置优先使用可见历史面板所在屏幕（关闭面板前捕获），没有主面板则用鼠标所在屏幕。同屏保留位置、跨屏居中，并限制在目标屏幕可见区内；不添加屏幕轮询。

- 开机启动状态在每次显示设置、可见设置窗口恢复／成为 key、应用取消隐藏／重新激活时与系统同步。用独立可观察状态刷新该开关，保留页面、原生输入控件和草稿；保存其他选项时合并最新启动状态。同步只读取登录项并更新偏好，不触发注册或重启 Monitor，不增加轮询。

- 历史面板以 760×520 为首选尺寸，逐次唤醒按目标屏幕可见区收缩宽高，SwiftUI 前景填满实际窗口，返回宽屏恢复首选尺寸。隐藏应用或最小化设置时卸载材质、约束和显示选项监听；历史面板另暂停键盘／外部点击监听。临时隐藏保留托管视图的编辑状态，恢复时挂载单层材质；真正关闭仍清空界面。隐藏和恢复不触发剪贴板提交，不增加轮询。

- 主窗口按住 ⌘ 在类型标签和“全部／置顶”按钮内用快捷键替换数量，松开恢复数量；悬停也可查看。复用可见窗口的本地按键监听观察 flagsChanged，原样传递事件，失去焦点或隐藏时清理状态。提示预留固定布局、不增加轮询或持续动画。

- AI 工具栏入口按用户要求作为持续推广效果：偏好设置可见时，不论当前页签／悬停状态，52×32pt 范围内保持金色大星稳定，七颗小星（包括左上两颗）以不同周期和起始相位柔和浮现、轻微上飘、消失；每次只有一个亮度峰值，不做主星摆动或整组同步呼吸。此为循环装饰动画的唯一例外；不增加定时器、粒子发射器或逐帧 AppKit／SwiftUI 重绘。隐藏、最小化、完全遮挡或关闭时移除动画；减少动态效果开启时显示静态金色图标。主星按图标区域中心对齐。AI 原生文字／留白的普通点击在设置可见时通过单个本地鼠标监听转交同一个按钮；Control 点击原样交回 AppKit，不触发切页；图标保留原生跟踪，拖出、失焦、跨窗口或丢失鼠标松开事件后取消跟踪。隐藏／最小化／关闭／完全遮挡时释放该监听，不添加全局监听或轮询。其余工具栏与窗口焦点仍使用原生行为。

- 原生窗口测试使用合成内容；退出前切回 accessory 并给 Dock 留出处理时间。测试入口 exec Python 监督进程，同一用户的原生窗口测试通过持有文件锁排队（锁文件不删除）；每次在 build/window-regressions/run-*/ 内独立生成应用和 results.json。直接启动并持有子进程及独立进程组，不扫描全局进程列表。构建失败、SIGINT／SIGTERM 和 120 秒测试超时只清理本次子进程及应用，锁保留到清理结束，结果留在各自目录；不能删除旧运行目录、清理真实 Clipboard 或重置 Dock。just test-window-runner 用无界面的隔离子进程覆盖这些边界。

- GitHub 发版正文将 CHANGELOG 对应版本段落注入模板中唯一的 `<!-- RELEASE_NOTES -->` 标记，缺失说明即失败。下载和校验说明分别列出 arm64／x86_64 文件名；校验文件第二列含 `dist/`，直接比对哈希。发布前的准备不提前写入尚未生成签名的 appcast 条目；正式更新条目由现有 CI 生成发布。

## Slice 节奏

见 `harness.json` 的 `slices[]` 与 `slice_rhythm`。每个 slice 以绿色、可运行、可提交的状态结束。

## Cross-platform desktop delivery

- Windows/Linux implementation is authorized through the stacked PR plan in `harness.json.cross_platform_delivery`, based on main `2fd2a97`. Preserve the existing macOS product and its macOS 13 minimum. System dependencies belong in platform adapters; shared business contracts stay portable.
- macOS keeps OSLog and CryptoKit; the non-Apple desktop uses a private-by-default stderr logger and Swift Crypto. Native clipboard, hotkey, credentials and rich-text preview adapters remain separate work.
- `.github/workflows/swift-portability.yml` runs Core tests and synthetic scenarios on Ubuntu/Windows plus Core/application regression on macOS for PRs, main changes and manual runs. Results and limitations belong in `docs/swift-portability.md` and `harness.json`.

- Cross-platform delivery uses stacked PRs: each layer targets the preceding branch, with implementation and native-test evidence. Do not mark untested keyboard/IME/DPI or unsupported Wayland capabilities as complete. The WinUI accessibility crash reproduced in the prior experiment must be resolved before accepting Windows UI controls.

- Native text clipboard adapters live in `DesktopClipboard` plus a C system shim. Windows uses Unicode clipboard APIs; Linux X11 uses XFixes notifications and an event-driven selection owner. Wayland is explicitly unsupported until CP7. Native tests exchange synthetic text with an independent process in the CI clipboard or isolated Xvfb; no user desktop clipboard is used locally.

- `Desktop/` is the Windows/Linux SwiftCrossUI application package. It explicitly uses GtkBackend; Windows GTK must include AccessKit and pass native UI Automation controls. The historical WinUI crash is not accepted as a successful port. Normal launches never seed sample history; only --smoke-root may inject synthetic fixtures. Keep GTK/Win32/X11 dependencies out of portable Core contracts.

- Desktop shell adapters use Windows tray/hotkey APIs or Linux SNI/dbusmenu/X11. Single-instance ownership is acquired before opening a profile; activation IPC carries no clipboard data. GTK hidden editors preserve drafts without adding UI polling. Persisted recording-on-start is distinct from runtime pause. Native shell tests use private Xvfb/DBus sessions and synthetic profile identities.

- Desktop rich capture uses Core RichClipboardAccess and a native adapter. Resolve blob bytes/decode images off UI; sensitive previews stay hidden. Desktop history archives are bounded, self-contained JSON (not macOS ZIP), exclude sensitive items and reject external blob references. Source IDs come from clipboard owner metadata, never the foreground app. INCR transfer timers exist only while outgoing transfers are active.

- DesktopServices owns OS credential/startup/OCR and bounded AI transport adapters. No plaintext credential fallback, keys in JSON or payloads in command arguments. Explicit remote/image/automatic opt-ins are separate; sensitive/concealed items fail before resolution or networking. Linux service tests run on a fresh DBus session with private keyring/config directories; Windows uses distinct synthetic credential/startup identities. GTK theme and language updates must preserve editors and require no UI polling.
- The pinned SwiftCrossUI GTK main-loop patch releases one-shot callback contexts and prevents zero-delay timeouts from starving AccessKit idle actions. Keep native accessibility focus/button checks as hard gates; a visible tree alone is insufficient.

- The pinned GTK AccessKit patch handles editable SetValue with native sensitivity/editability checks and schedules accessibility input at default priority. Optional CI diagnostics contain action/target IDs only, never text. UI Automation clients run MTA; native focus/action success remains required.
